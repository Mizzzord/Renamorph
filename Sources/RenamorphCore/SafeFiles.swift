import Foundation
import CryptoKit
import Darwin

public enum SafeFiles {
    public static func exists(_ path: String) -> Bool { var s = stat(); return lstat(path, &s) == 0 }
    public static func error(_ operation: String) -> RenamorphError { .message("\(operation): \(String(cString: strerror(errno)))") }
    public static func validateAncestors(_ path: String) throws {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" {
            var s = stat()
            guard lstat(current.path, &s) == 0 else { throw error("Нет доступа к \(current.path)") }
            guard (s.st_mode & S_IFMT) != S_IFLNK else { throw RenamorphError.message("Символические ссылки и пути через них не поддерживаются: \(current.path)") }
            current.deleteLastPathComponent()
        }
    }
    public static func checkVolume(_ path: String) throws {
        try validateAncestors(path)
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .isUbiquitousItemKey])
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw error("Не удалось определить файловую систему") }
        let name = withUnsafePointer(to: &fs.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        guard name == "apfs", values.volumeIsLocal == true, values.volumeIsInternal == true, values.volumeIsReadOnly != true else {
            throw RenamorphError.message("Поддерживается только доступный для записи APFS на внутреннем локальном диске; внешний/сетевой том отклонён")
        }
        guard values.isUbiquitousItem != true,
              !path.contains("/Library/Mobile Documents/"), !path.contains("/Library/CloudStorage/") else {
            throw RenamorphError.message("Облачные файлы и File Provider не поддерживаются в этой версии")
        }
    }
    private static func checkedStat(_ fd: Int32, maxBytes: Int64) throws -> stat {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw error("Не удалось прочитать атрибуты") }
        guard (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1 else { throw RenamorphError.message("Нужен обычный файл без hard links") }
        guard (s.st_flags & UInt32(SF_DATALESS)) == 0 else { throw RenamorphError.message("Облачный файл ещё не загружен; заполнители не обрабатываются") }
        guard s.st_size > 0, s.st_size <= maxBytes else { throw RenamorphError.message("Пустой файл или превышен лимит размера входа (\(maxBytes / 1024 / 1024) МБ)") }
        return s
    }
    private static func metadata(_ s: stat, digest: String) -> FileVersion {
        FileVersion(device: s.st_dev, inode: s.st_ino, size: s.st_size,
                    modifiedSeconds: Int64(s.st_mtimespec.tv_sec), modifiedNanos: Int64(s.st_mtimespec.tv_nsec),
                    changeSeconds: Int64(s.st_ctimespec.tv_sec), changeNanos: Int64(s.st_ctimespec.tv_nsec), digest: digest)
    }
    public static func fingerprint(_ path: String, maxBytes: Int64 = Int64.max) throws -> FileVersion {
        try validateAncestors(path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Нельзя прочитать файл") }
        defer { close(fd) }
        let before = try checkedStat(fd, maxBytes: maxBytes)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n >= 0 else { throw error("Ошибка чтения") }
            if n == 0 { break }
            hash.update(data: Data(buffer.prefix(n)))
        }
        let after = try checkedStat(fd, maxBytes: maxBytes)
        guard metadata(before, digest: "") == metadata(after, digest: "") else { throw RenamorphError.message("Файл изменяется во время чтения; повторите после завершения записи") }
        var current = stat()
        guard lstat(path, &current) == 0, metadata(current, digest: "") == metadata(after, digest: "") else { throw RenamorphError.message("Файл переименован или заменён во время чтения") }
        return metadata(after, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public static func requireVersion(_ path: String, _ expected: FileVersion) throws {
        guard try fingerprint(path) == expected else { throw RenamorphError.message("Вход изменён, заменён или переименован после решения. Устаревшее задание остановлено") }
    }
    public static func copyExclusive(from source: String, to destination: String, expected: FileVersion? = nil) throws -> FileVersion {
        let before = try fingerprint(source)
        if let expected, before != expected { throw RenamorphError.message("Исходная версия уже изменилась") }
        try validateAncestors(URL(fileURLWithPath: destination).deletingLastPathComponent().path)
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw error("Нельзя открыть источник") }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw error("Нельзя создать резерв или временный файл") }
        var completed = false
        defer { close(output); if !completed { unlink(destination) } }
        var buf = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let n = read(input, &buf, buf.count)
            guard n >= 0 else { throw error("Ошибка чтения источника") }
            if n == 0 { break }
            try buf.withUnsafeBytes { ptr in
                var offset = 0
                while offset < n {
                    let written = write(output, ptr.baseAddress!.advanced(by: offset), n - offset)
                    guard written > 0 else { throw error("Ошибка записи: проверьте свободное место") }
                    offset += written
                }
            }
        }
        guard fsync(output) == 0 else { throw error("Не удалось сохранить файл на диск") }
        let copied = try fingerprint(destination)
        guard before.sameContent(as: copied), try fingerprint(source) == before else { throw RenamorphError.message("Источник изменился во время копирования") }
        try syncDirectory(URL(fileURLWithPath: destination).deletingLastPathComponent().path)
        completed = true
        return copied
    }
    public static func syncFile(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("Нельзя синхронизировать файл") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw error("Ошибка синхронизации файла") }
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP { throw error("Ошибка полной синхронизации файла") }
    }
    public static func syncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw error("Нет доступа к каталогу") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw error("Не удалось синхронизировать каталог") }
    }
    public static func moveExclusive(_ source: String, _ destination: String) throws {
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else { throw error("Конфликт имени или ошибка перемещения") }
        try syncDirectory(URL(fileURLWithPath: destination).deletingLastPathComponent().path)
        try syncDirectory(URL(fileURLWithPath: source).deletingLastPathComponent().path)
    }
    public static func swap(_ staged: String, _ target: String) throws {
        guard renamex_np(staged, target, UInt32(RENAME_SWAP)) == 0 else { throw error("Не удалось выполнить безопасную замену") }
        try syncDirectory(URL(fileURLWithPath: target).deletingLastPathComponent().path)
        try syncDirectory(URL(fileURLWithPath: staged).deletingLastPathComponent().path)
    }
    public static func availableBytes(_ path: String) throws -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw error("Нельзя определить свободное место") }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
    public static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

public final class StateStore {
    public let directory: URL
    public let backups: URL
    public let url: URL
    private var lockFD: Int32 = -1
    public init(directory: URL) throws {
        self.directory = directory
        backups = directory.appendingPathComponent("Originals", isDirectory: true)
        url = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SafeFiles.validateAncestors(directory.path)
        lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw SafeFiles.error("Нет доступа к блокировке хранилища") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); lockFD = -1
            throw RenamorphError.message("Это хранилище уже открыто другим экземпляром Renamorph")
        }
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    public func load() throws -> PersistentState {
        guard SafeFiles.exists(url.path) else { return PersistentState() }
        let result = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: url))
        guard result.schema == 1 else { throw RenamorphError.message("Неизвестная версия журнала; автоматическая обработка отключена") }
        try result.settings.validate()
        return result
    }
    public func save(_ state: PersistentState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw SafeFiles.error("Не удалось защитить журнал") }
        try SafeFiles.syncFile(url.path)
        try SafeFiles.syncDirectory(directory.path)
    }
    public func backupUsage() throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }
}
