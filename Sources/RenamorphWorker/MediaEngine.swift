import Foundation
import Darwin
import RenamorphCore
import CryptoKit

// Spawn inherits the worker's process group, so cancellation terminates the entire conversion.
enum LocalTool {
    static func run(_ executable: URL, _ arguments: [String], input: String? = nil, lines: ((String) throws -> Void)? = nil) throws -> Data {
        let parent = ProcessInfo.processInfo.environment["RENAMORPH_IPC_DIRECTORY"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent("renamorph-tool-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout").path, stderr = directory.appendingPathComponent("stderr").path
        var descriptors: [Int32] = [-1, -1]
        if lines != nil {
            guard pipe(&descriptors) == 0 else { throw RenamorphError.message("Невозможно открыть канал проверки медиаданных") }
        }
        defer { descriptors.filter { $0 >= 0 }.forEach { close($0) } }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, input ?? "/dev/null", O_RDONLY, 0)
        if lines != nil {
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
            posix_spawn_file_actions_addclose(&actions, descriptors[0])
            posix_spawn_file_actions_addclose(&actions, descriptors[1])
        } else {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdout, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderr, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        let strings = ([executable.path] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        let code = posix_spawn(&pid, executable.path, &actions, nil, &argv, &envp)
        guard code == 0 else { throw RenamorphError.message("Не удалось запустить локальный движок: \(String(cString: strerror(code)))") }
        if let lines {
            close(descriptors[1]); descriptors[1] = -1
            let stream = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false)
            do {
                var pending = Data(), total = 0
                while let chunk = try stream.read(upToCount: 16384), !chunk.isEmpty {
                    total += chunk.count
                    guard total <= 512 * 1024 * 1024 else { throw RenamorphError.message("Описание декодированных кадров превышает 512 МБ") }
                    pending.append(chunk)
                    while let end = pending.firstIndex(of: 10) {
                        try lines(String(decoding: pending[..<end], as: UTF8.self))
                        pending.removeSubrange(...end)
                    }
                    guard pending.count < 32768 else { throw RenamorphError.message("Некорректная строка описания кадров") }
                }
                if !pending.isEmpty { try lines(String(decoding: pending, as: UTF8.self)) }
            } catch {
                kill(pid, SIGKILL)
                var abandoned: Int32 = 0
                while waitpid(pid, &abandoned, 0) == -1 && errno == EINTR {}
                throw error
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 { if errno != EINTR { throw RenamorphError.message("Ошибка ожидания движка") } }
        let diagnostic = try FileHandle(forReadingFrom: URL(fileURLWithPath: stderr))
        defer { try? diagnostic.close() }
        let message = String(decoding: try diagnostic.read(upToCount: 8192) ?? Data(), as: UTF8.self)
        guard status == 0 else {
            let signal = status & 0x7f
            if signal == SIGXFSZ { throw RenamorphError.message("Превышен лимит размера временного результата. Оригинал сохранён") }
            let reason = signal != 0 ? "сигнал \(signal)" : "код \((status >> 8) & 0xff)"
            throw RenamorphError.message("FFmpeg/ffprobe (\(reason)): " + (message.isEmpty ? "движок прерван; оригинал сохранён" : message))
        }
        guard message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RenamorphError.message("Медиаданные содержат ошибки декодирования: " + message)
        }
        if lines != nil { return Data() }
        let result = try FileHandle(forReadingFrom: URL(fileURLWithPath: stdout))
        defer { try? result.close() }
        let data = try result.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else { throw RenamorphError.message("Ответ медиадвижка превышает лимит") }
        return data
    }
}

enum MediaEngine {
    static let formats = "aac,aiff,asf,avi,caf,flac,matroska,webm,mov,mp3,mpeg,mpegts,ogg,wav,wv"
    static func inputOptions(_ request: WorkerRequest) -> [String] { ["-max_alloc", "268435456", "-max_pixels", String(request.maxPixels)] + ["-fflags", "+genpts", "-protocol_whitelist", "fd", "-format_whitelist", formats, "-threads", String(MediaToolchain.processingThreads), "-i", "fd:"] }
    static func tools() throws -> MediaToolchain {
        let tool = MediaToolchain()
        guard tool.available else { throw RenamorphError.message(tool.description) }
        return tool
    }
    static func inspect(_ request: WorkerRequest) throws -> ContentInfo {
        let tool = try tools()
        _ = try SafeFiles.fingerprint(request.input, maxBytes: request.maxBytes)
        let data = try LocalTool.run(tool.ffprobe!, ["-v", "error", "-max_alloc", "268435456", "-max_pixels", String(request.maxPixels), "-threads", String(MediaToolchain.processingThreads), "-fflags", "+genpts", "-protocol_whitelist", "fd", "-format_whitelist", formats,
            "-show_entries", "format=format_name,duration:stream=codec_name,codec_type,width,height,sample_rate,channels,duration,avg_frame_rate,pix_fmt,field_order,sample_aspect_ratio,color_transfer:stream_tags=alpha_mode:stream_disposition:stream_side_data=rotation", "-of", "json", "-i", "fd:"], input: request.input)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any], let name = format["format_name"] as? String,
              let durationString = format["duration"] as? String, let duration = Double(durationString),
              let streams = json["streams"] as? [[String: Any]], !streams.isEmpty else { throw RenamorphError.message("Контейнер или длительность не распознаны") }
        var mediaStreams: [MediaStream] = []
        var width = 0, height = 0, rotation = 0, fps = 0.0, videoFrames: Int?, aspect: String?
        for stream in streams {
            guard let kind = stream["codec_type"] as? String, ["audio", "video"].contains(kind),
                  let codec = stream["codec_name"] as? String,
                  (stream["disposition"] as? [String: Int])?["attached_pic"] != 1 else {
                throw RenamorphError.message("Дополнительные дорожки, обложки, вложения и потоки данных не поддерживаются; файл сохранён")
            }
            if ["smpte2084", "arib-std-b67"].contains(stream["color_transfer"] as? String ?? "") { throw RenamorphError.message("HDR-видео требует отдельного управления цветом и пока не поддерживается") }
            if kind == "video" {
                let pixels = stream["pix_fmt"] as? String ?? ""
                guard !pixels.contains("yuva"), !["rgba", "bgra", "argb", "abgr", "gbrap"].contains(where: { pixels.hasPrefix($0) }), (stream["tags"] as? [String: String])?["alpha_mode"] != "1" else { throw RenamorphError.message("Видео с прозрачностью пока не поддерживается") }
                guard ["progressive", "unknown", ""].contains(stream["field_order"] as? String ?? "") else { throw RenamorphError.message("Чересстрочное видео требует отдельной обработки и пока не поддерживается") }
                let sar = stream["sample_aspect_ratio"] as? String ?? "1:1"
                aspect = ["N/A", "0:1"].contains(sar) ? "1:1" : sar
                width = stream["width"] as? Int ?? 0; height = stream["height"] as? Int ?? 0
                let ratio = (stream["avg_frame_rate"] as? String ?? "0/1").split(separator: "/").compactMap { Double($0) }
                fps = ratio.count == 2 && ratio[1] > 0 ? ratio[0] / ratio[1] : 0
                let rawRotation = (stream["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
                rotation = ((rawRotation % 360) + 360) % 360
                guard width > 0, height > 0, width <= request.maxPixels / height, fps > 0 else { throw RenamorphError.message("Недопустимые размеры или частота кадров видео") }
            }
            mediaStreams.append(MediaStream(kind: kind, codec: codec, sampleRate: (stream["sample_rate"] as? String).flatMap(Int.init), channels: stream["channels"] as? Int, duration: (stream["duration"] as? String).flatMap(Double.init)))
        }
        let version: String
        if let bundled = tool.version { version = bundled }
        else { version = String(decoding: try LocalTool.run(tool.ffmpeg!, ["-version"]), as: UTF8.self).components(separatedBy: "\n").first ?? "FFmpeg" }
        var media = MediaInfo(duration: duration, streams: mediaStreams, rotation: rotation, frameRate: fps, engineVersion: version)
        guard media.valid else { throw RenamorphError.message("Поддерживается до одной видео- и одной аудиодорожки, длительность до 24 часов, 1–8 аудиоканалов") }
        var hasher = SHA256(), first: Double?, previous: Double?, count = 0, audioFrames = 0
        _ = try LocalTool.run(tool.ffprobe!, ["-v", "error", "-max_alloc", "268435456", "-max_pixels", String(request.maxPixels), "-threads", String(MediaToolchain.processingThreads), "-fflags", "+genpts", "-protocol_whitelist", "fd", "-format_whitelist", formats, "-show_frames", "-show_entries", "frame=media_type,best_effort_timestamp_time,nb_samples:frame_side_data=", "-of", "compact=p=0:nk=0", "-i", "fd:"], input: request.input, lines: { line in
            if line.isEmpty { return }
            var fields: [String: String] = [:]
            for part in line.split(separator: "|") {
                let pair = part.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            if fields["media_type"] == "audio" {
                guard let samples = fields["nb_samples"].flatMap(Int.init), samples > 0, samples <= 1_048_576 else { throw RenamorphError.message("Аудиокадр не декодирован полностью") }
                audioFrames += 1
            } else if fields["media_type"] == "video" {
                guard let value = fields["best_effort_timestamp_time"].flatMap(Double.init), value.isFinite, previous == nil || value > previous! else { throw RenamorphError.message("Неизвестные или непоследовательные временные метки кадров") }
                if first == nil { first = value }
                previous = value; count += 1
                guard value - first! < 86401 else { throw RenamorphError.message("Временные метки превышают лимит длительности") }
                let milliseconds = Int64(((value - first!) * 1000).rounded())
                hasher.update(data: Data("\(milliseconds),".utf8))
            } else { throw RenamorphError.message("Неизвестный тип декодированного кадра") }
        })
        guard media.audio == nil || audioFrames > 0 else { throw RenamorphError.message("Аудиокадры не декодированы") }
        if media.video != nil {
            guard count > 0 else { throw RenamorphError.message("Видеокадры не декодированы") }
            videoFrames = count
            media.videoTimingDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        media.sampleAspectRatio = aspect
        media.videoFrames = videoFrames
        guard media.valid else { throw RenamorphError.message("Поддерживается до одной видео- и одной аудиодорожки, длительность до 24 часов, 1–8 аудиоканалов") }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: request.input)); defer { try? file.close() }
        let header = try file.read(upToCount: 4096) ?? Data()
        let actual: FileFormat
        if name.contains("mov") {
            actual = header.count >= 12 && String(decoding: header[8..<12], as: UTF8.self) == "qt  " ? .mov : (media.video == nil ? .m4a : .mp4)
        } else if name.contains("matroska") {
            let bytes = [UInt8](header)
            guard bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]),
                  let index = (4..<max(4, min(bytes.count - 2, 64))).first(where: { bytes[$0] == 0x42 && bytes[$0 + 1] == 0x82 }),
                  bytes[index + 2] & 0x80 != 0 else { throw RenamorphError.message("EBML DocType не распознан") }
            let length = Int(bytes[index + 2] & 0x7f)
            guard index + 3 + length <= bytes.count else { throw RenamorphError.message("Неполный заголовок EBML") }
            let type = String(decoding: bytes[(index + 3)..<(index + 3 + length)], as: UTF8.self)
            guard ["webm", "matroska"].contains(type) else { throw RenamorphError.message("Не поддерживается EBML DocType \(type)") }
            actual = type == "webm" ? .webm : .mkv
        }
        else if name == "ogg" { actual = media.audio?.codec == "opus" ? .opus : .ogg }
        else if name == "asf" { actual = media.video == nil ? .wma : .wmv }
        else if name == "mpegts" { actual = .ts }
        else if let value = FileFormat(rawValue: name), value.isMedia { actual = value }
        else { throw RenamorphError.message("Не поддерживается медиаконтейнер \(name)") }
        guard actual.family == .video || media.video == nil else { throw RenamorphError.message("Видео в аудиоконтейнере не поддерживается") }
        var info = ContentInfo(format: actual, width: width, height: height, hasAlpha: false)
        info.media = media
        if actual == .opus { info.compatibleFormats = [.ogg] }
        if actual == .m4a { info.compatibleFormats = [.mp4] }
        return info
    }
    static func run(_ request: WorkerRequest) throws -> ContentInfo {
        let info = try inspect(request)
        if request.action == "inspect" { return info }
        guard request.action == "convert", let target = request.target, let output = request.output, !SafeFiles.exists(output) else { throw RenamorphError.message("Неверный запрос или занятый временный путь") }
        _ = try Route.find(info.format, target)
        let plan = try MediaPlan.resolve(info, target: target, options: request.options)
        let tool = try tools()
        var arguments = ["-hide_banner", "-v", "error", "-xerror", "-nostdin", "-n", "-filter_threads", "2", "-filter_complex_threads", "1"] + inputOptions(request)
        if plan.videoCodec != nil { arguments += ["-map", "0:v:0"] }
        if plan.audioCodec != nil { arguments += ["-map", "0:a:0"] }
        arguments += ["-map_metadata", "-1", "-map_chapters", "-1", "-threads", String(MediaToolchain.processingThreads)]
        if plan.copyStreams { arguments += ["-c", "copy"] }
        else {
            if let encoder = plan.videoEncoder {
                arguments += ["-c:v", encoder, "-pix_fmt", "yuv420p", "-fps_mode", "passthrough"]
                if encoder == "mpeg4" { arguments += ["-q:v", "3"] }
                else { arguments += ["-crf", String(request.options.videoCRF)] }
                if encoder == "libx264" { arguments += ["-preset", "medium"] }
                if encoder == "libvpx-vp9" { arguments += ["-b:v", "0"] }
            }
            if let encoder = plan.audioEncoder {
                arguments += ["-c:a", encoder, "-ar", String(plan.sampleRate!)]
                if ["aac", "libmp3lame", "libvorbis", "libopus"].contains(encoder) { arguments += ["-b:a", "\(request.options.audioBitrate)k"] }
                if ["flac", "wavpack", "alac"].contains(encoder) { arguments += ["-sample_fmt", encoder == "flac" ? "s32" : "s32p", "-bits_per_raw_sample", "24"] }
                if encoder == "wavpack" { arguments += ["-frame_size:a", String(min(32768, max(128, plan.sampleRate! / 2)))] }
            }
        }
        let muxers: [FileFormat: String] = [.m4a: "ipod", .aac: "adts", .opus: "opus", .ogg: "ogg", .mp4: "mp4", .mov: "mov", .mkv: "matroska", .webm: "webm", .avi: "avi", .mp3: "mp3", .wav: "wav", .aiff: "aiff", .flac: "flac", .caf: "caf", .wv: "wv"]
        guard let muxer = muxers[target] else { throw RenamorphError.message("Мультиплексор цели не реализован") }
        if [.mp4, .mov, .m4a].contains(target) { arguments += ["-movflags", "+faststart"] }
        arguments += ["-f", muxer, output]
        _ = try LocalTool.run(tool.ffmpeg!, arguments, input: request.input)
        try SafeFiles.syncFile(output)
        return info
    }
}
