import Foundation
import RenamorphCore
import ImageIO
import CoreGraphics
import Darwin

enum RasterEngine {
    static func signature(_ data: Data) throws -> FileFormat {
        let bytes = [UInt8](data.prefix(4096))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return .png }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return .jpeg }
        if bytes.starts(with: [0x49, 0x49, 0x2a, 0]) || bytes.starts(with: [0x4d, 0x4d, 0, 0x2a]) { return .tiff }
        if bytes.starts(with: [0x42, 0x4d]) { return .bmp }
        if bytes.starts(with: Array("GIF8".utf8)) { return .gif }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF", String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return .webp }
        if bytes.count >= 16, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let length = bytes[0..<4].reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 16, length <= bytes.count, length % 4 == 0 else { throw RenamorphError.message("Неполная таблица брендов изображения ISO BMFF") }
            let brands = ([8] + Array(stride(from: 16, to: length, by: 4))).map { String(bytes: bytes[$0..<($0 + 4)], encoding: .ascii) ?? "" }
            if brands.contains("avif") || brands.contains("avis") { return .avif }
            if brands.contains(where: { ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains($0) }) { return .heic }
        }
        throw RenamorphError.message("Неизвестное содержимое: сигнатура не принадлежит поддерживаемым изображениям")
    }
    static func load(_ request: WorkerRequest) throws -> (CGImageSource, CGImage, ContentInfo) {
        _ = try SafeFiles.fingerprint(request.input, maxBytes: request.maxBytes)
        let data = try Data(contentsOf: URL(fileURLWithPath: request.input))
        let format = try signature(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source) as String?,
              uti == format.uti || (format == .heic && uti == "public.heif") || (format == .webp && uti == "public.webp"),
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw RenamorphError.message("Сигнатура и декодер не согласованы либо файл повреждён")
        }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else { throw RenamorphError.message("Многостраничные изображения и анимации не поддерживаются (кадров: \(count))") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= request.maxPixels / height else {
            throw RenamorphError.message("Размер изображения неизвестен или превышает лимит \(request.maxPixels) пикселей")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw RenamorphError.message("Не удалось полностью декодировать изображение")
        }
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        return (source, image, ContentInfo(format: format, width: width, height: height, hasAlpha: alpha, frames: count, orientation: orientation))
    }
    static func run(_ request: WorkerRequest) throws -> ContentInfo {
        let (source, decoded, info) = try load(request)
        if request.action == "inspect" { return info }
        guard request.action == "convert", let target = request.target, let output = request.output else { throw RenamorphError.message("Неверный запрос движку") }
        _ = try Route.find(info.format, target)
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard target == .webp || types.contains(target.uti) else { throw RenamorphError.message("В этой ОС отсутствует ImageIO-кодировщик \(target.title)") }
        guard !SafeFiles.exists(output) else { throw RenamorphError.message("Временный результат уже существует") }
        guard (0...1).contains(request.options.jpegQuality) else { throw RenamorphError.message("Качество должно быть от 0 до 1") }
        if [.jpeg, .bmp].contains(target) && info.hasAlpha && request.options.alpha == .reject {
            throw RenamorphError.message("Вход содержит альфа-канал. Для JPEG/BMP явно выберите белый фон или другой формат")
        }
        let normalized: CGImage
        if info.orientation == 1 { normalized = decoded }
        else {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw RenamorphError.message("Не удалось применить ориентацию") }
            normalized = thumbnail
        }
        let preserveAlpha = ![.jpeg, .bmp].contains(target) && info.hasAlpha
        let alphaInfo: CGImageAlphaInfo = preserveAlpha ? .premultipliedLast : .noneSkipLast
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: normalized.width, height: normalized.height, bitsPerComponent: 8, bytesPerRow: normalized.width * 4, space: color, bitmapInfo: alphaInfo.rawValue) else {
            throw RenamorphError.message("Недостаточно памяти для растра")
        }
        let rect = CGRect(x: 0, y: 0, width: normalized.width, height: normalized.height)
        if !preserveAlpha { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect) }
        context.draw(normalized, in: rect)
        let intermediate = output + ".normalized.png"
        defer { if target == .webp { try? FileManager.default.removeItem(atPath: intermediate) } }
        guard let rendered = context.makeImage(), let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: target == .webp ? intermediate : output) as CFURL, (target == .webp ? FileFormat.png.uti : target.uti) as CFString, 1, nil) else {
            throw RenamorphError.message("Невозможно создать временный результат")
        }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: request.options.jpegQuality, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenamorphError.message("Ошибка кодирования/записи. Проверьте свободное место и права") }
        if target == .webp {
            let tool = try MediaEngine.tools()
            _ = try LocalTool.run(tool.ffmpeg!, ["-v", "error", "-xerror", "-nostdin", "-n", "-protocol_whitelist", "fd", "-f", "png_pipe", "-i", "fd:", "-frames:v", "1", "-c:v", "libwebp", "-lossless", "1", "-threads", "1", "-f", "webp", output], input: intermediate)
        }
        try SafeFiles.syncFile(output)
        return info
    }
}

_ = setpgid(0, 0)
umask(0o077)
let ownerPID = getppid()
let parentMonitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
parentMonitor.schedule(deadline: .now() + 1, repeating: 1)
parentMonitor.setEventHandler { if getppid() != ownerPID { kill(-getpgrp(), SIGKILL) } }
parentMonitor.resume()
guard CommandLine.arguments.count == 3 else { exit(64) }
let responseURL = URL(fileURLWithPath: CommandLine.arguments[2])
do {
    let requestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard requestData.count < 64 * 1024 else { throw RenamorphError.message("Запрос слишком большой") }
    let request = try JSONDecoder().decode(WorkerRequest.self, from: requestData)
    guard request.maxPixels > 0, request.maxPixels <= 200_000_000, request.maxBytes > 0, request.maxBytes <= 256 * 1024 * 1024 * 1024, request.maxOutputBytes == nil || (request.maxOutputBytes! > 0 && request.maxOutputBytes! <= 256 * 1024 * 1024 * 1024) else { throw RenamorphError.message("Неверные ресурсные лимиты") }
    var limit = rlimit(rlim_cur: rlim_t(request.maxOutputBytes ?? max(request.maxBytes * 4, Int64(request.maxPixels) * 8 + 16 * 1024 * 1024)), rlim_max: rlim_t(request.maxOutputBytes ?? max(request.maxBytes * 4, Int64(request.maxPixels) * 8 + 16 * 1024 * 1024)))
    _ = setrlimit(RLIMIT_FSIZE, &limit)
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: request.input))
    let header = try handle.read(upToCount: 4096) ?? Data(); try handle.close()
    let text = String(decoding: header, as: UTF8.self)
    let result: ContentInfo
    if (try? RasterEngine.signature(header)) != nil { result = try RasterEngine.run(request) }
    else if text.hasPrefix("WEBVTT") || text.hasPrefix("\u{feff}WEBVTT") || (text.contains(" --> ") && (text.first?.isNumber == true || text.first == "\u{feff}")) { result = try SubtitleEngine.run(request) }
    else { result = try MediaEngine.run(request) }
    try JSONEncoder().encode(WorkerResponse(info: result)).write(to: responseURL, options: .atomic)
} catch {
    try? JSONEncoder().encode(WorkerResponse(error: error.localizedDescription)).write(to: responseURL, options: .atomic)
    exit(1)
}
