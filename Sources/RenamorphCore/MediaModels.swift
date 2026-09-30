import Foundation
import CryptoKit

public struct MediaStream: Codable, Equatable {
    public var kind: String
    public var codec: String
    public var sampleRate: Int?
    public var channels: Int?
    public var duration: Double?
    public init(kind: String, codec: String, sampleRate: Int? = nil, channels: Int? = nil, duration: Double? = nil) {
        self.kind = kind; self.codec = codec; self.sampleRate = sampleRate; self.channels = channels; self.duration = duration
    }
}
public struct MediaInfo: Codable, Equatable {
    public var duration: Double
    public var streams: [MediaStream]
    public var rotation: Int
    public var frameRate: Double
    public var sampleAspectRatio: String?
    public var videoTimingDigest: String?
    public var videoFrames: Int?
    public var engineVersion: String
    public init(duration: Double, streams: [MediaStream], rotation: Int, frameRate: Double, engineVersion: String) {
        self.duration = duration; self.streams = streams; self.rotation = rotation; self.frameRate = frameRate; self.engineVersion = engineVersion
    }
    public var audio: MediaStream? { streams.first { $0.kind == "audio" } }
    public var video: MediaStream? { streams.first { $0.kind == "video" } }
    public var valid: Bool {
        duration.isFinite && duration > 0 && duration <= 86400 && frameRate.isFinite && frameRate >= 0 && frameRate <= 1000 &&
        [0, 90, 180, 270].contains(rotation) && (1...2).contains(streams.count) &&
        streams.filter { $0.kind == "audio" }.count <= 1 && streams.filter { $0.kind == "video" }.count <= 1 &&
        streams.allSatisfy { s in
            !s.codec.isEmpty && ["audio", "video"].contains(s.kind) &&
            (s.kind != "audio" || ((1...8).contains(s.channels ?? 0) && (8000...384000).contains(s.sampleRate ?? 0)))
        }
    }
}

public struct MediaPlan: Codable, Equatable {
    public var copyStreams: Bool
    public var extractAudio: Bool
    public var videoEncoder: String?
    public var audioEncoder: String?
    public var videoCodec: String?
    public var audioCodec: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var title: String {
        (extractAudio ? "Извлечение аудио · " : "") + (copyStreams ? "перепаковка без перекодирования потоков" : "перекодирование")
    }
    public static func resolve(_ source: ContentInfo, target: FileFormat, options: ConversionOptions) throws -> Self {
        guard let info = source.media, info.valid, options.valid else { throw RenamorphError.message("Нет допустимого описания медиапотоков или параметров") }
        let video = target.family == .video ? info.video : nil
        let audio = info.audio
        guard target.family != .video || video != nil else { throw RenamorphError.message("В источнике нет видеопотока") }
        guard target.family != .audio || audio != nil else { throw RenamorphError.message("В источнике нет аудиопотока для извлечения") }
        let extract = info.video != nil && target.family == .audio
        let audioCompatible: [FileFormat: Set<String>] = [
            .mp3: ["mp3"], .wav: ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"], .aiff: ["pcm_s16be", "pcm_s24be"],
            .flac: ["flac"], .caf: ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "alac"], .wv: ["wavpack"], .m4a: ["aac", "alac"], .aac: ["aac"], .ogg: ["vorbis"], .opus: ["opus"],
            .mp4: ["aac"], .mov: ["aac"], .webm: ["opus", "vorbis"], .avi: ["mp3", "pcm_s16le", "pcm_s24le"],
            .mkv: ["aac", "mp3", "flac", "vorbis", "opus", "pcm_s16le", "pcm_s24le"]
        ]
        let videoCompatible: [FileFormat: Set<String>] = [.mp4: ["h264", "hevc"], .mov: ["h264", "hevc"], .mkv: ["h264", "hevc", "vp8", "vp9", "av1", "mpeg4", "mpeg2video", "wmv2"], .webm: ["vp8", "vp9", "av1"], .avi: ["mpeg4", "mjpeg"]]
        let canCopy = (video == nil || videoCompatible[target]?.contains(video!.codec) == true) &&
            (audio == nil || audioCompatible[target]?.contains(audio!.codec) == true) &&
            (audio == nil || options.audioSampleRate == 0 || options.audioSampleRate == audio?.sampleRate)
        if options.mediaMode == .remuxOnly && !canCopy { throw RenamorphError.message("Перепаковка без перекодирования для этих потоков и цели невозможна. Выберите другой режим") }
        if canCopy && options.mediaMode != .transcode {
            return Self(copyStreams: true, extractAudio: extract, videoEncoder: nil, audioEncoder: nil, videoCodec: video?.codec, audioCodec: audio?.codec, sampleRate: audio?.sampleRate, channels: audio?.channels)
        }
        let videoEncoders: [FileFormat: (String, String)] = [.mp4: ("libx264", "h264"), .mov: ("libx264", "h264"), .mkv: ("libx264", "h264"), .webm: ("libvpx-vp9", "vp9"), .avi: ("mpeg4", "mpeg4")]
        let audioEncoders: [FileFormat: (String, String)] = [.mp3: ("libmp3lame", "mp3"), .wav: ("pcm_s24le", "pcm_s24le"), .aiff: ("pcm_s24be", "pcm_s24be"), .caf: ("pcm_s24le", "pcm_s24le"), .wv: ("wavpack", "wavpack"), .flac: ("flac", "flac"), .m4a: (options.m4aCodec.rawValue, options.m4aCodec.rawValue), .aac: ("aac", "aac"), .ogg: ("libvorbis", "vorbis"), .opus: ("libopus", "opus"), .mp4: ("aac", "aac"), .mov: ("aac", "aac"), .mkv: ("aac", "aac"), .webm: ("libopus", "opus"), .avi: ("pcm_s24le", "pcm_s24le")]
        let a = audio != nil ? audioEncoders[target] : nil
        let v = video != nil ? videoEncoders[target] : nil
        guard video == nil || v != nil, audio == nil || a != nil else { throw RenamorphError.message("Не реализован кодек результата") }
        let rate = audio.map { options.audioSampleRate == 0 ? $0.sampleRate! : options.audioSampleRate }
        let actualRate = a?.1 == "opus" ? 48000 : rate
        if a?.1 == "mp3", (audio?.channels ?? 0) > 2 { throw RenamorphError.message("MP3 поддерживается только для mono/stereo; автоматического сведения каналов нет") }
        if a?.1 == "mp3", ![8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000].contains(actualRate ?? 0) { throw RenamorphError.message("Для MP3 выберите частоту 44100 или 48000 Гц") }
        return Self(copyStreams: false, extractAudio: extract, videoEncoder: v?.0, audioEncoder: a?.0, videoCodec: v?.1, audioCodec: a?.1, sampleRate: actualRate, channels: audio?.channels)
    }
}

public struct MediaToolchain {
    public let directory: URL?
    private let problem: String?
    public var available: Bool { directory != nil && problem == nil }
    public var ffmpeg: URL? { directory?.appendingPathComponent("ffmpeg") }
    public var ffprobe: URL? { directory?.appendingPathComponent("ffprobe") }
    public var version: String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return directory.flatMap { Self.versions[$0.path] }
    }
    public static var processingThreads: Int { min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)) }
    public var description: String { problem ?? directory.map { (version ?? "FFmpeg / ffprobe") + " · " + $0.path } ?? "FFmpeg / ffprobe не найдены: соберите движок через scripts/build-media.sh" }
    public init() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["RENAMORPH_MEDIA_BIN"]
        let candidates = override.map { [URL(fileURLWithPath: $0)] } ?? [
            executable.appendingPathComponent("Media"), executable.appendingPathComponent("../Helpers/Media").standardizedFileURL,
            URL(fileURLWithPath: "/opt/homebrew/opt/ffmpeg-full/bin"), URL(fileURLWithPath: "/usr/local/opt/ffmpeg-full/bin")
        ]
        directory = candidates.first { url in ["ffmpeg", "ffprobe"].allSatisfy { FileManager.default.isExecutableFile(atPath: url.appendingPathComponent($0).path) } }
        problem = directory.flatMap { Self.check($0) }
    }
    private static let lock = NSLock()
    private static var capabilities: [String: String] = [:]
    private static var versions: [String: String] = [:]
    private struct BundledCapabilities: Decodable {
        var version: String
        var encoders: [String]
        var decoders: [String]
        var binaries: [String: String]
    }
    private static func check(_ directory: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = capabilities[directory.path] { return cached.isEmpty ? nil : cached }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("renamorph-capabilities-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let issue: String
        do {
            let candidates = [directory.appendingPathComponent("capabilities.json"), directory.appendingPathComponent("../../Resources/MediaCapabilities.json").standardizedFileURL]
            let metadata = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
            if FileManager.default.fileExists(atPath: metadata.path) {
                let data = try Data(contentsOf: metadata)
                guard data.count <= 128 * 1024 else { throw RenamorphError.message("Некорректный реестр движка") }
                let manifest = try JSONDecoder().decode(BundledCapabilities.self, from: data)
                for name in ["ffmpeg", "ffprobe"] {
                    let executable = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
                    let digest = SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined()
                    guard manifest.binaries[name] == digest else { throw RenamorphError.message("Проверка комплектности \(name) не пройдена. Пересоберите приложение") }
                }
                let missing = requiredEncoders.filter { !manifest.encoders.contains($0) } + requiredDecoders.filter { !manifest.decoders.contains($0) }
                guard missing.isEmpty else { throw RenamorphError.message("Отсутствуют кодеки: " + missing.joined(separator: ", ")) }
                versions[directory.path] = manifest.version
                capabilities[directory.path] = ""
                return nil
            }
            var missing: [String] = []
            for (table, required) in [("encoders", requiredEncoders), ("decoders", requiredDecoders)] {
                guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw RenamorphError.message("Нет доступа к временному каталогу") }
                let output = try FileHandle(forWritingTo: path); defer { try? output.close() }
                let process = Process(); process.executableURL = directory.appendingPathComponent("ffmpeg")
                process.arguments = ["-hide_banner", "-" + table]; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
                try process.run()
                if done.wait(timeout: .now() + 3) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw RenamorphError.message("FFmpeg не отвечает при проверке кодеков") }
                guard process.terminationStatus == 0 else { throw RenamorphError.message("FFmpeg не запускается; проверьте библиотеки и совместимость с macOS") }
                let read = try FileHandle(forReadingFrom: path); defer { try? read.close() }
                let listing = String(decoding: try read.read(upToCount: 1024 * 1024) ?? Data(), as: UTF8.self)
                let names = Set(listing.components(separatedBy: "\n").compactMap { line -> String? in
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    return fields.count >= 2 && fields[0].count == 6 ? String(fields[1]) : nil
                })
                missing += required.filter { !names.contains($0) }
            }
            issue = missing.isEmpty ? "" : "В установленном FFmpeg отсутствуют кодеки: " + missing.joined(separator: ", ")
        } catch { issue = error.localizedDescription }
        capabilities[directory.path] = issue
        return issue.isEmpty ? nil : issue
    }
    private static let requiredEncoders = ["libx264", "libvpx-vp9", "mpeg4", "aac", "alac", "libmp3lame", "pcm_s24le", "pcm_s24be", "flac", "wavpack", "libvorbis", "libopus", "libwebp"]
    private static let requiredDecoders = ["png", "h264", "hevc", "mp3float", "aac", "pcm_s24le", "pcm_s24be", "flac", "wavpack", "wmav2", "wmv2", "mpeg2video", "vorbis", "opus", "vp8", "vp9", "alac", "libdav1d"]
}

public enum ResultValidation {
    public static func check(source: ContentInfo, output: ContentInfo, target: FileFormat, options: ConversionOptions) throws {
        guard output.isCompatible(with: target) else { throw RenamorphError.message("Фактический формат результата не соответствует цели") }
        if source.isCompatible(with: target), source.media != nil {
            var expected = source.media
            expected?.engineVersion = output.media?.engineVersion ?? ""
            guard expected == output.media, source.width == output.width, source.height == output.height else { throw RenamorphError.message("Копия медиаданных отличается от источника") }
            return
        }
        if let inputMedia = source.media {
            guard let result = output.media, result.valid else { throw RenamorphError.message("Результат не содержит проверенных медиапотоков") }
            let plan = try MediaPlan.resolve(source, target: target, options: options)
            let expectedDuration = target.family == .audio ? (inputMedia.audio?.duration ?? inputMedia.duration) : inputMedia.duration
            guard abs(result.duration - expectedDuration) <= 0.25,
                  result.streams.count == (plan.videoCodec == nil ? 0 : 1) + (plan.audioCodec == nil ? 0 : 1),
                  result.video?.codec == plan.videoCodec, result.audio?.codec == plan.audioCodec,
                  result.audio?.channels == plan.channels, result.audio?.sampleRate == plan.sampleRate else {
                throw RenamorphError.message("Проверка медиарезультата не пройдена: длительность, кодеки, потоки, частота или каналы отличаются от плана")
            }
            if plan.videoCodec != nil {
                let rotated = !plan.copyStreams && [90, 270].contains(inputMedia.rotation)
                guard output.width == (rotated ? source.height : source.width), output.height == (rotated ? source.width : source.height), result.rotation == (plan.copyStreams ? inputMedia.rotation : 0), result.sampleAspectRatio == inputMedia.sampleAspectRatio, result.videoFrames == inputMedia.videoFrames, result.videoTimingDigest == inputMedia.videoTimingDigest else {
                    throw RenamorphError.message("Не совпадают геометрия, ориентация или частота кадров видео")
                }
            }
        } else if source.format.family == .subtitles {
            guard source.semanticDigest == output.semanticDigest, source.frames == output.frames else { throw RenamorphError.message("Текст или тайм-коды субтитров изменились") }
        } else {
            let copy = source.isCompatible(with: target)
            let rotated = (5...8).contains(source.orientation) && !copy
            guard output.frames == 1, output.width == (rotated ? source.height : source.width), output.height == (rotated ? source.width : source.height), output.orientation == (copy ? source.orientation : 1), !source.hasAlpha || output.hasAlpha || [.jpeg, .bmp].contains(target) else {
                throw RenamorphError.message("Результат не прошёл проверку размеров, кадров, ориентации или альфа-канала")
            }
        }
    }
}
