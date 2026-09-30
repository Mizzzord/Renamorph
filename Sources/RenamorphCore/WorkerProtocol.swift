import Foundation

public struct WorkerRequest: Codable {
    public var action: String
    public var input: String
    public var output: String?
    public var target: FileFormat?
    public var options: ConversionOptions
    public var maxPixels: Int
    public var maxOutputBytes: Int64?
    public var maxBytes: Int64
    public init(action: String, input: String, output: String? = nil, target: FileFormat? = nil, options: ConversionOptions = .init(), maxPixels: Int = 40_000_000, maxBytes: Int64 = 128 * 1024 * 1024, maxOutputBytes: Int64? = nil) {
        self.action = action; self.input = input; self.output = output; self.target = target; self.options = options; self.maxPixels = maxPixels; self.maxBytes = maxBytes; self.maxOutputBytes = maxOutputBytes
    }
}
public struct WorkerResponse: Codable {
    public var info: ContentInfo?
    public var error: String?
    public init(info: ContentInfo? = nil, error: String? = nil) { self.info = info; self.error = error }
}
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public func check() throws { if isCancelled { throw RenamorphError.message("Операция отменена") } }
}
public final class WorkerClient {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    public var available: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }
    public func perform(_ request: WorkerRequest, timeout: Double, cancellation: Cancellation) throws -> ContentInfo {
        guard available else { throw RenamorphError.message("RenamorphWorker отсутствует или не исполняемый: \(executable.path)") }
        try cancellation.check()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("renamorph-ipc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("request.json"), output = directory.appendingPathComponent("response.json")
        try JSONEncoder().encode(request).write(to: input)
        let process = Process()
        process.executableURL = executable
        process.arguments = [input.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["RENAMORPH_IPC_DIRECTORY"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let start = Date()
        var aborted = false
        while exited.wait(timeout: .now() + 0.05) == .timedOut {
            if cancellation.isCancelled || Date().timeIntervalSince(start) > timeout {
                aborted = true
                let pid = process.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
                process.waitUntilExit()
                break
            }
        }
        if aborted {
            try cancellation.check()
            throw RenamorphError.message("Превышено время работы движка (\(Int(timeout)) с); оригинал сохранён")
        }
        try cancellation.check()
        guard SafeFiles.exists(output.path) else { throw RenamorphError.message("Движок завершился без ответа (код \(process.terminationStatus))") }
        let data = try Data(contentsOf: output)
        guard data.count < 64 * 1024 else { throw RenamorphError.message("Некорректный ответ движка") }
        let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
        if let message = response.error { throw RenamorphError.message(message) }
        guard process.terminationStatus == 0, let info = response.info else { throw RenamorphError.message("Движок завершился с ошибкой \(process.terminationStatus)") }
        if info.format.isMedia {
            guard info.media?.valid == true, info.media?.video == nil || (info.width > 0 && info.height > 0 && info.width <= request.maxPixels / info.height) else { throw RenamorphError.message("Недопустимое описание медиапотоков") }
        } else if info.format.family == .subtitles {
            guard info.frames > 0, info.semanticDigest?.count == 64 else { throw RenamorphError.message("Недопустимое описание субтитров") }
        } else {
            guard info.width > 0, info.height > 0, info.width <= request.maxPixels / info.height, info.frames == 1, (1...8).contains(info.orientation) else { throw RenamorphError.message("Недопустимые размеры изображения") }
        }
        return info
    }
}
