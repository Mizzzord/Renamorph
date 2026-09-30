import Foundation
import ImageIO

public enum RenamorphError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

public enum FileFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png, tiff, heic, bmp, webp, gif, avif
    case mp3, wav, flac, aiff, m4a, aac, ogg, opus, wma, caf, wv
    case mp4, mov, mkv, webm, avi, mpeg, wmv, ts
    case srt, vtt
    public enum Family: String, CaseIterable { case raster = "Изображения", audio = "Аудио", video = "Видео", subtitles = "Субтитры" }
    public var family: Family {
        switch self {
        case .jpeg, .png, .tiff, .heic, .bmp, .webp, .gif, .avif: return .raster
        case .mp3, .wav, .flac, .aiff, .m4a, .aac, .ogg, .opus, .wma, .caf, .wv: return .audio
        case .srt, .vtt: return .subtitles
        default: return .video
        }
    }
    public var isMedia: Bool { family == .audio || family == .video }
    public static var rasters: [Self] { allCases.filter { $0.family == .raster } }
    public static var audio: [Self] { allCases.filter { $0.family == .audio } }
    public static var video: [Self] { allCases.filter { $0.family == .video } }
    public static let rasterOutputs: [Self] = [.jpeg, .png, .tiff, .heic, .bmp, .webp, .avif]
    public static let audioOutputs: [Self] = [.mp3, .wav, .flac, .aiff, .m4a, .aac, .ogg, .opus, .caf, .wv]
    public static let videoOutputs: [Self] = [.mp4, .mov, .mkv, .webm, .avi]
    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var uti: String {
        switch self {
        case .jpeg: return "public.jpeg"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .webp: return "org.webmproject.webp"
        default: return ""
        }
    }
    public static func from(extension ext: String) -> Self? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        case "bmp": return .bmp
        case "aif", "aifc": return .aiff
        case "wave": return .wav
        case "m4v": return .mp4
        case "mpg", "vob": return .mpeg
        case "mts", "m2ts": return .ts
        case "webvtt": return .vtt
        default: return Self(rawValue: ext.lowercased())
        }
    }
}

public enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case ask, automatic, deny
    public var id: String { rawValue }
    public var title: String { [.ask: "Подтверждать", .automatic: "Автоматически", .deny: "Запретить"][self]! }
}
public enum AlphaPolicy: String, Codable, CaseIterable, Identifiable {
    case reject, white
    public var id: String { rawValue }
    public var title: String { self == .reject ? "Отклонять прозрачность → JPEG/BMP" : "Белый фон для JPEG/BMP" }
}
public enum GroupPolicy: String, Codable, CaseIterable, Identifiable {
    case undecided, prepareAll
    public var id: String { rawValue }
    public var title: String { self == .undecided ? "Публикация групп не согласована" : "Подготовить всю группу, затем публиковать" }
}
public struct ConversionOptions: Codable, Equatable {
    public var jpegQuality: Double = 0.9
    public var alpha: AlphaPolicy = .reject
    public var audioBitrate: Int = 192
    public var audioSampleRate: Int = 0
    public var videoCRF: Int = 23
    public var mediaMode: MediaMode = .preferRemux
    public var m4aCodec: M4ACodec = .aac
    public init() {}
    public var summary: String { "JPEG/HEIC/AVIF \(Int(jpegQuality * 100))%; \(alpha.title); 8-bit sRGB; метаданные удаляются" }
    public func summary(for format: FileFormat) -> String {
        if format.isMedia {
            let audio = format == .m4a && m4aCodec == .alac ? "ALAC до 24 бит" : ([.wav, .aiff, .flac, .caf, .wv].contains(format) ? "аудио до 24 бит" : "аудио \(audioBitrate) кбит/с")
            return "\(mediaMode.title). При перекодировании: \(audio), \(audioSampleRate == 0 ? "частота источника" : "\(audioSampleRate) Гц")" + (format.family == .video ? (format == .avi ? "; видео MPEG-4 q=3, аудио PCM 24 бит" : "; видео CRF \(videoCRF)") : "")
        }
        if format.family == .subtitles { return "UTF-8; текст и тайм-коды без оформления" }
        return summary + (format == .webp ? "; WebP lossless после нормализации" : "")
    }
    public var valid: Bool { jpegQuality.isFinite && (0...1).contains(jpegQuality) && (32...320).contains(audioBitrate) && [0, 44100, 48000].contains(audioSampleRate) && (16...35).contains(videoCRF) }
    private enum CodingKeys: String, CodingKey { case jpegQuality, alpha, audioBitrate, audioSampleRate, videoCRF, mediaMode, m4aCodec }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.9
        alpha = try c.decodeIfPresent(AlphaPolicy.self, forKey: .alpha) ?? .reject
        audioBitrate = try c.decodeIfPresent(Int.self, forKey: .audioBitrate) ?? 192
        audioSampleRate = try c.decodeIfPresent(Int.self, forKey: .audioSampleRate) ?? 0
        videoCRF = try c.decodeIfPresent(Int.self, forKey: .videoCRF) ?? 23
        mediaMode = try c.decodeIfPresent(MediaMode.self, forKey: .mediaMode) ?? .preferRemux
        m4aCodec = try c.decodeIfPresent(M4ACodec.self, forKey: .m4aCodec) ?? .aac
    }
}
public enum M4ACodec: String, Codable, CaseIterable, Identifiable {
    case aac, alac
    public var id: String { rawValue }
    public var title: String { self == .aac ? "AAC · с потерями" : "ALAC · до 24 бит без потерь после подготовки PCM" }
}
public enum MediaMode: String, Codable, CaseIterable, Identifiable {
    case preferRemux, transcode, remuxOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .preferRemux: return "Перепаковка при совместимости"
        case .transcode: return "Перекодирование"
        case .remuxOnly: return "Только перепаковка"
        }
    }
}
public struct PairRule: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var source: FileFormat
    public var target: FileFormat
    public var action: RuleAction
    public var options: ConversionOptions
    public init(source: FileFormat, target: FileFormat, action: RuleAction, options: ConversionOptions) {
        self.source = source; self.target = target; self.action = action; self.options = options
    }
}
public struct WatchFolder: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var path: String
    public var bookmark: Data?
    public init(url: URL) {
        path = url.standardizedFileURL.path
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
public struct Settings: Codable, Equatable {
    public var folders: [WatchFolder] = []
    public var exclusions: [String] = []
    public var handleNewFiles = false
    public var defaultAction: RuleAction = .ask
    public var options = ConversionOptions()
    public var rules: [PairRule] = []
    public var groupPolicy: GroupPolicy = .undecided
    public var backupLimitBytes: Int64 = 2 * 1024 * 1024 * 1024
    public var maxInputBytes: Int64 = 2048 * 1024 * 1024
    public var maxPixels: Int = 40_000_000
    public var workerTimeout: Double = 900
    public var paused = false
    public init() {}
    public func validate() throws {
        guard backupLimitBytes > 0, maxInputBytes > 0, maxInputBytes <= 8 * 1024 * 1024 * 1024, maxPixels > 0, maxPixels <= 200_000_000,
              workerTimeout >= 1, workerTimeout <= 3600,
              options.valid, rules.allSatisfy({ $0.options.valid }) else {
            throw RenamorphError.message("Некорректные настройки лимитов или качества")
        }
    }
    public func effective(source: FileFormat, target: FileFormat) throws -> EffectiveSettings {
        let matches = rules.filter { $0.source == source && $0.target == target }
        guard matches.count <= 1 else { throw RenamorphError.message("Конфликт правил \(source.title) → \(target.title): удалите дубликаты") }
        if let rule = matches.first {
            return EffectiveSettings(action: rule.action, options: rule.options, origin: "Правило \(source.title) → \(target.title)")
        }
        return EffectiveSettings(action: defaultAction, options: options, origin: "Общие настройки")
    }
}
public struct EffectiveSettings: Codable, Equatable {
    public var action: RuleAction
    public var options: ConversionOptions
    public var origin: String
}
public struct FileVersion: Codable, Equatable {
    public var device: Int32
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanos: Int64
    public var changeSeconds: Int64
    public var changeNanos: Int64
    public var digest: String
    public var identity: String { "\(device):\(inode)" }
    public func sameContent(as other: Self) -> Bool { size == other.size && digest == other.digest }
}
public struct ContentInfo: Codable, Equatable {
    public var format: FileFormat
    public var width: Int
    public var height: Int
    public var hasAlpha: Bool
    public var frames: Int
    public var orientation: Int
    public var media: MediaInfo?
    public var semanticDigest: String?
    public var compatibleFormats: [FileFormat]?
    public func isCompatible(with target: FileFormat) -> Bool { format == target || compatibleFormats?.contains(target) == true }
    public var summary: String {
        if let media { return String(format: "%.2f с", media.duration) + "; " + media.streams.map { "\($0.kind): \($0.codec)" }.joined(separator: ", ") }
        if format.family == .subtitles { return "\(frames) реплик" }
        return "\(width) × \(height) px"
    }
    public init(format: FileFormat, width: Int, height: Int, hasAlpha: Bool, frames: Int = 1, orientation: Int = 1) {
        self.format = format; self.width = width; self.height = height; self.hasAlpha = hasAlpha; self.frames = frames; self.orientation = orientation
    }
}
public enum JobState: String, Codable {
    case inspecting, awaiting, queued, preparing, running, validating, prepared, publishing, succeeded, cancelled, failed, needsRecovery, restoring, restored, restoreConflict, unsupported
    public var title: String {
        switch self {
        case .inspecting: return "Распознавание и проверка"
        case .awaiting: return "Ожидает решения"
        case .queued: return "В очереди"
        case .preparing: return "Резервирование"
        case .running: return "Преобразование"
        case .validating: return "Проверка результата"
        case .prepared: return "Подготовлено — выберите политику группы"
        case .publishing: return "Публикация"
        case .succeeded: return "Готово"
        case .cancelled: return "Отменено"
        case .failed: return "Ошибка"
        case .needsRecovery: return "Требуется восстановление"
        case .restoring: return "Восстановление"
        case .restored: return "Оригинал восстановлен"
        case .restoreConflict: return "Конфликт восстановления"
        case .unsupported: return "Не поддерживается"
        }
    }
    public var isInFlight: Bool { [.inspecting, .queued, .preparing, .running, .validating, .publishing, .restoring].contains(self) }
}
public enum OutputState: String, Codable {
    case waiting, preparing, validated, publishing, published, cancelled, restored, conflict
    public var title: String {
        switch self {
        case .waiting: return "Ожидает"
        case .preparing: return "Подготавливается"
        case .validated: return "Проверен"
        case .publishing: return "Публикуется"
        case .published: return "Опубликован"
        case .cancelled: return "Отменён"
        case .restored: return "Восстановлен"
        case .conflict: return "Конфликт"
        }
    }
}
public struct OutputRecord: Codable, Identifiable {
    public var id = UUID()
    public var path: String
    public var format: FileFormat
    public var settings: EffectiveSettings
    public var state: OutputState = .waiting
    public var stagePath: String?
    public var version: FileVersion?
    public var operation: String
    public var losses: String
    public var engine: String?
}
public struct Job: Codable, Identifiable {
    public var id = UUID()
    public var sourcePath: String
    public var previousPath: String?
    public var source: FileVersion
    public var image: ContentInfo?
    public var outputs: [OutputRecord] = []
    public var state: JobState = .awaiting
    public var message = ""
    public var createdAt = Date()
    public var updatedAt = Date()
    public var backupPath: String?
    public var workspacePath: String?
    public var approvedVersion: FileVersion?
    public var publicationStarted = false
    public var originalParkedPath: String?
    public var restoreTarget: String?
    public var restoreStage: String?
    public var progress: Double = 0
    public var groupPolicy: GroupPolicy = .undecided
    public var trigger: String
    public var name: String { URL(fileURLWithPath: sourcePath).lastPathComponent }
    public init(sourcePath: String, previousPath: String?, source: FileVersion, trigger: String) {
        self.sourcePath = sourcePath; self.previousPath = previousPath; self.source = source; self.trigger = trigger
    }
}
public struct OwnFile: Codable {
    public var path: String
    public var identity: String
    public var digest: String
}
public struct PersistentState: Codable {
    public var schema = 1
    public var settings = Settings()
    public var jobs: [Job] = []
    public var ownFiles: [OwnFile] = []
    public init() {}
}
public struct RenameRequest {
    public var targets: [(format: FileFormat, path: String)]
    public var duplicateCount: Int
    public static func parse(path: String) throws -> Self {
        let url = URL(fileURLWithPath: path)
        let suffix = url.pathExtension.lowercased()
        let parts = suffix.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !suffix.isEmpty, parts.count <= FileFormat.allCases.count * 2 else { throw RenamorphError.message("Не удалось разобрать целевые расширения") }
        var seen = Set<FileFormat>()
        var targets: [(FileFormat, String)] = []
        var duplicates = 0
        for part in parts {
            guard let format = FileFormat.from(extension: part) else { throw RenamorphError.message("Расширение .\(part) не поддерживается: маршрут не реализован") }
            guard seen.insert(format).inserted else { duplicates += 1; continue }
            let result = parts.count == 1 ? path : url.deletingPathExtension().appendingPathExtension(part).path
            targets.append((format, result))
        }
        return Self(targets: targets, duplicateCount: duplicates)
    }
}
public struct Route: Identifiable {
    private static let rasterInputTypes = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
    private static let rasterOutputTypes = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    public var source: FileFormat
    public var target: FileFormat
    public var id: String { "\(source.rawValue)-\(target.rawValue)" }
    public var operation: String {
        if source.family == .subtitles { return "Преобразование текстовых субтитров" }
        if source.family == .video && target.family == .audio { return "Извлечение аудио" }
        if source.isMedia { return "Перепаковка или перекодирование по свойствам потоков" }
        return "Декодирование и кодирование растра"
    }
    public var needsFFmpeg: Bool { source.isMedia || target == .webp }
    public var unavailableReason: String? {
        if needsFFmpeg, !MediaToolchain().available { return MediaToolchain().description }
        if source.family == .raster {
            if !Self.rasterInputTypes.contains(source.uti) { return "В этой macOS отсутствует ImageIO-декодировщик \(source.title)" }
            if target != .webp && !Self.rasterOutputTypes.contains(target.uti) { return "В этой macOS отсутствует ImageIO-кодировщик \(target.title)" }
        }
        return nil
    }
    public var engine: String { needsFFmpeg ? "FFmpeg / ffprobe" : (source.family == .subtitles ? "Локальный парсер UTF-8" : "Apple ImageIO") }
    public var validation: String {
        if source.isMedia { return "Контейнер, кодеки, полное декодирование, длительность, потоки, размеры, частота и каналы" }
        if source.family == .subtitles { return "Повторный разбор, число реплик, текст и тайм-коды" }
        return "Сигнатура, полное декодирование, один кадр, размеры, ориентация, альфа"
    }
    public var losses: String {
        if source.family == .subtitles { return "Оформление, стили и позиционирование не поддерживаются; такие входы отклоняются" }
        if source.isMedia { return "Теги и главы не переносятся. Перекодирование может терять качество; PCM/FLAC ограничены 24 битами, Opus использует 48 кГц. " + (target.family == .audio && source.family == .video ? "Видео намеренно исключается." : (source.family == .video ? "При перекодировании видео — 8-bit YUV420. HDR и дополнительные потоки отклоняются." : "Число аудиоканалов сохраняется.")) }
        return "8-bit sRGB; удаление исходных метаданных, HDR и дополнительных представлений" + ([.jpeg, .heic, .avif].contains(target) ? "; \(target.title) с потерями" : "; возможна потеря глубины и цветового охвата") + (target == .jpeg ? "; прозрачность по настройке" : "")
    }
    public static var all: [Route] {
        let raster = FileFormat.rasters.flatMap { s in FileFormat.rasterOutputs.filter { $0 != s }.map { Route(source: s, target: $0) } }
        let audio = FileFormat.audio.flatMap { s in FileFormat.audioOutputs.filter { $0 != s && !(s == .opus && $0 == .ogg) }.map { Route(source: s, target: $0) } }
        let video = FileFormat.video.flatMap { s in (FileFormat.videoOutputs + FileFormat.audioOutputs).filter { $0 != s && !(s == .wmv && $0 == .avi) }.map { Route(source: s, target: $0) } }
        return raster + audio + video + [Route(source: .srt, target: .vtt), Route(source: .vtt, target: .srt)]
    }
    public static func find(_ source: FileFormat, _ target: FileFormat) throws -> Self {
        if source == .wmv && target == .avi { throw RenamorphError.message("WMV → AVI отключено: сохранение временных меток не подтверждено. Выберите MP4, MOV, MKV или WebM") }
        guard let route = all.first(where: { $0.source == source && $0.target == target }) else { throw RenamorphError.message("\(source.title) → \(target.title): маршрут кодирования не реализован") }
        if let reason = route.unavailableReason { throw RenamorphError.message(reason) }
        return route
    }
}
