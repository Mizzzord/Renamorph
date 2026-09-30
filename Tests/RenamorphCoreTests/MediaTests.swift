import Testing
import Foundation
@testable import RenamorphCore

extension CoreTests {
    @Test func testCompatibleCopyAfterEngineUpgradeKeepsSemanticValidation() throws {
        let input = folder.appendingPathComponent("source.opus")
        try makeMedia(input, format: .opus)
        let current = try inspect(input.path)
        var recorded = current; recorded.media?.engineVersion = "older engine"
        try ResultValidation.check(source: recorded, output: current, target: .ogg, options: .init())
        var changed = current; changed.media?.streams[0].sampleRate = 44100
        expectThrows(try ResultValidation.check(source: recorded, output: changed, target: .ogg, options: .init()))
    }
    @Test func testCAFAndWavPackPreservePCMAndExactUndo() throws {
        let tool = try requireValue(MediaToolchain().ffmpeg)
        func pcmDigest(_ input: String) throws -> String {
            let raw = folder.appendingPathComponent(UUID().uuidString + ".pcm")
            let process = Process(); process.executableURL = tool
            process.arguments = ["-v", "error", "-i", input, "-map", "0:a:0", "-c:a", "pcm_s24le", "-f", "s24le", raw.path]
            try process.run(); process.waitUntilExit(); expectEqual(process.terminationStatus, 0)
            return try SafeFiles.fingerprint(raw.path).digest
        }
        let old = folder.appendingPathComponent("song.caf")
        try makeMedia(old, format: .caf)
        let expectedPCM = try pcmDigest(old.path)
        let path = folder.appendingPathComponent("song.wv,wav,m4a")
        try FileManager.default.moveItem(at: old, to: path)
        let version = try SafeFiles.fingerprint(path.path)
        var job = Job(sourcePath: path.path, previousPath: old.path, source: version, trigger: "rename")
        job.image = try inspect(path.path); job.approvedVersion = version; job.groupPolicy = .prepareAll
        for (target, destination) in try RenameRequest.parse(path: path.path).targets {
            var effective = try settings.effective(source: .caf, target: target)
            effective.options.m4aCodec = .alac
            job.outputs.append(OutputRecord(path: destination, format: target, settings: effective, operation: "test", losses: "test"))
        }
        let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectEqual(job.state, .succeeded)
        for output in job.outputs { expectEqual(try pcmDigest(output.path), expectedPCM) }
        try tx.undo(&job)
        expectEqual(try SafeFiles.fingerprint(old.path).digest, version.digest)
    }
    @Test func testFullDecodeRejectsDamagedFLACAndPreservesBytes() throws {
        let input = folder.appendingPathComponent("damaged.jpg")
        try makeMedia(input, format: .flac, seconds: "3")
        var data = try Data(contentsOf: input)
        let middle = data.count / 2
        data.replaceSubrange(middle..<(middle + 128), with: Data(repeating: 0xff, count: 128))
        try data.write(to: input)
        let version = try SafeFiles.fingerprint(input.path)
        expectThrows(try inspect(input.path))
        expectEqual(try SafeFiles.fingerprint(input.path), version)
    }
    func makeMedia(_ path: URL, format: FileFormat, seconds: String = "1") throws {
        let arguments: [FileFormat: [String]] = [
            .mp3: ["-c:a", "libmp3lame", "-f", "mp3"], .wav: ["-c:a", "pcm_s16le", "-f", "wav"],
            .flac: ["-c:a", "flac", "-f", "flac"], .aiff: ["-c:a", "pcm_s16be", "-f", "aiff"],
            .caf: ["-c:a", "pcm_s24le", "-f", "caf"], .wv: ["-c:a", "wavpack", "-f", "wv"],
            .m4a: ["-c:a", "aac", "-f", "ipod"], .aac: ["-c:a", "aac", "-f", "adts"],
            .ogg: ["-c:a", "libvorbis", "-f", "ogg"], .opus: ["-c:a", "libopus", "-f", "opus"], .wma: ["-c:a", "wmav2", "-f", "asf"],
            .mp4: ["-c:v", "libx264", "-c:a", "aac", "-f", "mp4"], .mov: ["-c:v", "libx264", "-c:a", "aac", "-f", "mov"],
            .mkv: ["-c:v", "libx264", "-c:a", "aac", "-f", "matroska"], .webm: ["-c:v", "libvpx-vp9", "-c:a", "libopus", "-f", "webm"],
            .avi: ["-c:v", "mpeg4", "-c:a", "libmp3lame", "-f", "avi"], .mpeg: ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpeg"],
            .wmv: ["-c:v", "wmv2", "-c:a", "wmav2", "-f", "asf"], .ts: ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "mpegts"]
        ]
        var args = ["-v", "error", "-nostdin", "-n"]
        if format.family == .video { args += ["-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25"] }
        args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", seconds, "-ac", "2", "-threads", "1"]
        args += try requireValue(arguments[format]); args += [path.path]
        let process = Process(); process.executableURL = try requireValue(MediaToolchain().ffmpeg); process.arguments = args
        try process.run(); process.waitUntilExit(); expectEqual(process.terminationStatus, 0)
    }
    @Test func testAllAudioVideoRoutesWithContentDetectionAndValidation() throws {
        var count = 0
        for source in FileFormat.allCases.filter({ $0.isMedia }) {
            let input = folder.appendingPathComponent(source.rawValue + ".misnamed")
            try makeMedia(input, format: source)
            let info = try inspect(input.path)
            expectEqual(info.format, source)
            for route in Route.all.filter({ $0.source == source }) {
                let output = folder.appendingPathComponent(route.id + ".temporary")
                let options = ConversionOptions()
                do {
                    _ = try worker.perform(WorkerRequest(action: "convert", input: input.path, output: output.path, target: route.target, options: options), timeout: 30, cancellation: Cancellation())
                    let result = try inspect(output.path)
                    try ResultValidation.check(source: info, output: result, target: route.target, options: options)
                    count += 1
                } catch { Issue.record("\(route.id): \(error.localizedDescription)") }
            }
        }
        expectEqual(count, 213)
    }
    @Test func testMediaTransactionGroupAndExactUndo() throws {
        let old = folder.appendingPathComponent("song.wav")
        try makeMedia(old, format: .wav)
        let path = folder.appendingPathComponent("song.mp3,flac")
        try FileManager.default.moveItem(at: old, to: path)
        let version = try SafeFiles.fingerprint(path.path)
        var job = Job(sourcePath: path.path, previousPath: old.path, source: version, trigger: "rename")
        job.image = try inspect(path.path); job.approvedVersion = version; job.groupPolicy = .prepareAll
        for (target, destination) in try RenameRequest.parse(path: path.path).targets {
            job.outputs.append(OutputRecord(path: destination, format: target, settings: try settings.effective(source: .wav, target: target), operation: "test", losses: "test"))
        }
        let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectEqual(job.state, .succeeded)
        expectEqual(try inspect(job.outputs[0].path).format, .mp3)
        expectEqual(try inspect(job.outputs[1].path).format, .flac)
        try tx.undo(&job)
        expectEqual(try SafeFiles.fingerprint(old.path).digest, version.digest)
        expectEqual(job.state, .restored)
    }
    @Test func testRemuxPlanAndOnlyRemuxRejectsIncompatibleCodecs() throws {
        let input = folder.appendingPathComponent("video.mp4")
        try makeMedia(input, format: .mp4)
        let info = try inspect(input.path)
        var options = ConversionOptions(); options.mediaMode = .remuxOnly
        expectTrue(try MediaPlan.resolve(info, target: .mkv, options: options).copyStreams)
        expectThrows(try MediaPlan.resolve(info, target: .webm, options: options))
        options.mediaMode = .transcode
        expectFalse(try MediaPlan.resolve(info, target: .mkv, options: options).copyStreams)
        let target = folder.appendingPathComponent("transcoded.mkv")
        _ = try worker.perform(WorkerRequest(action: "convert", input: input.path, output: target.path, target: .mkv, options: options), timeout: 20, cancellation: Cancellation())
        try ResultValidation.check(source: info, output: inspect(target.path), target: .mkv, options: options)
    }
    @Test func testSubtitlesRoundTripAndUnsupportedStyling() throws {
        let input = folder.appendingPathComponent("captions.wrong")
        let text = "1\n00:00:01,200 --> 00:00:03,450\nПривет, мир!\nВторая строка.\n\n2\n00:00:03,500 --> 00:00:04,000\nКонец.\n"
        try Data(text.utf8).write(to: input)
        let source = try inspect(input.path)
        expectEqual(source.format, .srt)
        let vtt = folder.appendingPathComponent("captions.vtt")
        _ = try worker.perform(WorkerRequest(action: "convert", input: input.path, output: vtt.path, target: .vtt), timeout: 10, cancellation: Cancellation())
        let actual = try inspect(vtt.path)
        try ResultValidation.check(source: source, output: actual, target: .vtt, options: .init())
        let back = folder.appendingPathComponent("back.srt")
        _ = try worker.perform(WorkerRequest(action: "convert", input: vtt.path, output: back.path, target: .srt), timeout: 10, cancellation: Cancellation())
        expectEqual(try String(contentsOf: back), text)
        try Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<b>Styled</b>\n".utf8).write(to: input)
        expectThrows(try inspect(input.path))
    }
    @Test func testOldOptionsAndMediaAliases() throws {
        let options = try JSONDecoder().decode(ConversionOptions.self, from: Data("{\"jpegQuality\":0.8,\"alpha\":\"white\"}".utf8))
        expectEqual(options.jpegQuality, 0.8); expectEqual(options.mediaMode, .preferRemux)
        expectEqual(options.m4aCodec, .aac)
        expectEqual(FileFormat.from(extension: "m4v"), .mp4)
        expectEqual(FileFormat.from(extension: "aif"), .aiff)
        expectEqual(FileFormat.from(extension: "m2ts"), .ts)
        expectEqual(Route.all.count, 264)
        expectThrows(try Route.find(.wmv, .avi))
    }
}

extension CoreTests {
    @Test func testMediaOutputLimitAndCancellationPreserveInput() throws {
        let input = folder.appendingPathComponent("source.mp4")
        try makeMedia(input, format: .mp4, seconds: "30")
        let version = try SafeFiles.fingerprint(input.path)
        let output = folder.appendingPathComponent("output.wav")
        expectThrows(try worker.perform(WorkerRequest(action: "convert", input: input.path, output: output.path, target: .wav, maxOutputBytes: 64 * 1024), timeout: 20, cancellation: Cancellation()))
        expectEqual(try SafeFiles.fingerprint(input.path), version)
        let cancel = Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { cancel.cancel() }
        expectThrows(try worker.perform(WorkerRequest(action: "convert", input: input.path, output: folder.appendingPathComponent("cancel.webm").path, target: .webm), timeout: 20, cancellation: cancel))
        expectEqual(try SafeFiles.fingerprint(input.path), version)
    }
    @Test func testMediaAdditionalTracksAndExternalPlaylistsRejected() throws {
        let input = folder.appendingPathComponent("two-audio.mkv")
        let p = Process(); p.executableURL = try requireValue(MediaToolchain().ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=duration=1", "-map", "0:a", "-map", "0:a", "-c:a", "flac", input.path]
        try p.run(); p.waitUntilExit(); expectEqual(p.terminationStatus, 0)
        expectThrows(try inspect(input.path))
        let playlist = folder.appendingPathComponent("external.mp4")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttps://example.invalid/private.ts\n#EXT-X-ENDLIST\n".utf8).write(to: playlist)
        expectThrows(try inspect(playlist.path))
    }
    @Test func testMediaFrameGeometryAndCountMismatchRejected() throws {
        let input = folder.appendingPathComponent("video.mov")
        try makeMedia(input, format: .mov)
        let original = try inspect(input.path)
        var altered = original; altered.format = .mp4; altered.media?.videoFrames = 20
        expectThrows(try ResultValidation.check(source: original, output: altered, target: .mp4, options: .init()))
        altered = original; altered.format = .mp4; altered.width += 2
        expectThrows(try ResultValidation.check(source: original, output: altered, target: .mp4, options: .init()))
    }
}
