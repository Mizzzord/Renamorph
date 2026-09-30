import Foundation
import CryptoKit
import RenamorphCore

enum SubtitleEngine {
    struct Cue: Codable { var start: Int; var end: Int; var text: String }
    static func time(_ value: String, format: FileFormat) throws -> Int {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3 || (format == .vtt && parts.count == 2) else { throw RenamorphError.message("Некорректный тайм-код субтитров") }
        let seconds = parts.last!.split(separator: ".")
        guard seconds.count == 2, seconds[0].count == 2, seconds[1].count == 3,
              let s = Int(seconds[0]), let ms = Int(seconds[1]), let m = Int(parts[parts.count - 2]),
              let h = parts.count == 3 ? Int(parts[0]) : 0, h >= 0, h < 1000, (0...59).contains(m), (0...59).contains(s), (0...999).contains(ms) else { throw RenamorphError.message("Некорректный тайм-код субтитров") }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }
    static func stamp(_ milliseconds: Int, format: FileFormat) -> String {
        String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3600000, milliseconds / 60000 % 60, milliseconds / 1000 % 60, format == .srt ? "," : ".", milliseconds % 1000)
    }
    static func run(_ request: WorkerRequest) throws -> ContentInfo {
        _ = try SafeFiles.fingerprint(request.input, maxBytes: min(request.maxBytes, 16 * 1024 * 1024))
        let data = try Data(contentsOf: URL(fileURLWithPath: request.input))
        guard var text = String(data: data, encoding: .utf8) else { throw RenamorphError.message("Субтитры должны быть UTF-8") }
        if text.first == "\u{feff}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let format: FileFormat = text.hasPrefix("WEBVTT") ? .vtt : .srt
        var blocks = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n")
        if format == .vtt {
            guard blocks.first == "WEBVTT" else { throw RenamorphError.message("Метаданные заголовка WebVTT не поддерживаются") }
            blocks.removeFirst()
        }
        var cues: [Cue] = []
        for block in blocks where !block.isEmpty {
            var lines = block.components(separatedBy: "\n")
            if format == .srt {
                guard let first = lines.first, Int(first) == cues.count + 1 else { throw RenamorphError.message("Ожидался последовательный номер реплики SRT") }
                lines.removeFirst()
            }
            guard lines.count >= 2 else { throw RenamorphError.message("Неполная реплика субтитров") }
            let timing = lines.removeFirst().components(separatedBy: " --> ")
            guard timing.count == 2 else { throw RenamorphError.message("Стили, идентификаторы и размещение реплик пока не поддерживаются") }
            let start = try time(timing[0], format: format), end = try time(timing[1], format: format)
            let payload = lines.joined(separator: "\n")
            guard end > start, !payload.isEmpty, !payload.contains("<"), !payload.contains(">"), !payload.contains("{"), !payload.contains("}"), !payload.contains("&"), !payload.contains("\0") else { throw RenamorphError.message("Поддерживаются только текстовые реплики без разметки и с допустимыми интервалами") }
            cues.append(Cue(start: start, end: end, text: payload))
        }
        guard !cues.isEmpty, cues.count <= 100000 else { throw RenamorphError.message("Пустой или слишком большой файл субтитров") }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var info = ContentInfo(format: format, width: 0, height: 0, hasAlpha: false, frames: cues.count)
        info.semanticDigest = SHA256.hash(data: try encoder.encode(cues)).map { String(format: "%02x", $0) }.joined()
        if request.action == "inspect" { return info }
        guard let output = request.output, let target = request.target, target.family == .subtitles, !SafeFiles.exists(output) else { throw RenamorphError.message("Некорректная цель субтитров") }
        let result = (target == .vtt ? "WEBVTT\n\n" : "") + cues.enumerated().map { index, cue in
            (target == .srt ? "\(index + 1)\n" : "") + stamp(cue.start, format: target) + " --> " + stamp(cue.end, format: target) + "\n" + cue.text
        }.joined(separator: "\n\n") + "\n"
        try Data(result.utf8).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        try SafeFiles.syncFile(output)
        return info
    }
}
