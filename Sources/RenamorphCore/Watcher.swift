import Foundation
import CoreServices
import Darwin

public struct ObservedFile: Codable, Equatable {
    public var path: String
    public var identity: String
    public var size: Int64
    public var modified: String
    public var changed: String
    public var extensionName: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
    public init?(path: String) {
        var s = stat()
        guard lstat(path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, s.st_nlink == 1,
              (s.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
        self.path = path
        identity = "\(s.st_dev):\(s.st_ino):\(s.st_birthtimespec.tv_sec):\(s.st_birthtimespec.tv_nsec)"
        size = s.st_size
        modified = "\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)"
        changed = "\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }
}
public struct Observation {
    public var file: ObservedFile
    public var previousPath: String?
}
public enum SnapshotDiff {
    public static func candidates(old: [String: ObservedFile], new: [String: ObservedFile], includeNew: Bool) -> [Observation] {
        new.values.compactMap { file in
            if let previous = old[file.identity] {
                guard previous.path != file.path, previous.extensionName != file.extensionName else { return nil }
                return Observation(file: file, previousPath: previous.path)
            }
            return includeNew ? Observation(file: file, previousPath: nil) : nil
        }
    }
}
public final class FolderWatcher {
    private let queue = DispatchQueue(label: "local.renamorph.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var settings = Settings()
    private var snapshot: [String: ObservedFile] = [:]
    private var rootIdentities: [String: String] = [:]
    private var pending: [String: Observation] = [:]
    private var mustRebaseline = true
    public var onObservation: ((Observation) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onRootMoved: ((UUID, String) -> Void)?
    public init() {}
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; timer?.cancel() }
    public func configure(_ settings: Settings) {
        queue.async { self.configureOnQueue(settings) }
    }
    private func configureOnQueue(_ settings: Settings) {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        debounce?.cancel(); timer?.cancel()
        self.settings = settings; mustRebaseline = true; pending.removeAll(); snapshot.removeAll(); rootIdentities.removeAll()
        guard !settings.paused, !settings.folders.isEmpty else { onStatus?(settings.paused ? "Наблюдение приостановлено" : "Выберите папку для наблюдения"); return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, context, count, _, flags, _ in
            guard let context else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(context).takeUnretainedValue()
            let resetFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            if (0..<count).contains(where: { flags[$0] & resetFlags != 0 }) { watcher.mustRebaseline = true }
            watcher.scheduleScan()
        }, &context, settings.folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        guard let stream else { onStatus?("Не удалось создать наблюдатель FSEvents"); return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { onStatus?("Нет доступа для запуска FSEvents"); return }
        scan()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.mustRebaseline = true; self.scan()
        }
        timer.resume(); self.timer = timer
    }
    public func rescan() { queue.async { self.mustRebaseline = true; self.scan() } }
    private func scheduleScan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        debounce = work; queue.asyncAfter(deadline: .now() + 0.65, execute: work)
    }
    private func scan() {
        do {
            var fresh: [String: ObservedFile] = [:]
            for folder in settings.folders {
                if !SafeFiles.exists(folder.path), let bookmark = folder.bookmark {
                    var stale = false
                    if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), resolved.path != folder.path, SafeFiles.exists(resolved.path) {
                        onRootMoved?(folder.id, resolved.path)
                        onStatus?("Корень перемещён; восстанавливается базовый снимок")
                        mustRebaseline = true
                        return
                    }
                }
                try SafeFiles.checkVolume(folder.path)
                var rootStat = stat()
                guard lstat(folder.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw RenamorphError.message("Наблюдаемый корень недоступен: \(folder.path)") }
                let identity = "\(rootStat.st_dev):\(rootStat.st_ino)"
                if let old = rootIdentities[folder.path], old != identity { mustRebaseline = true }
                rootIdentities[folder.path] = identity
                var scanError: Error?
                guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder.path), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else {
                    throw RenamorphError.message("Нет доступа для чтения каталога \(folder.path)")
                }
                for case let url as URL in enumerator {
                    if settings.exclusions.contains(where: { SafeFiles.isWithin(url.path, root: $0) }) || url.lastPathComponent.hasPrefix(".renamorph-") {
                        enumerator.skipDescendants(); continue
                    }
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isPackageKey])
                    if values.isSymbolicLink == true || values.isPackage == true { enumerator.skipDescendants(); continue }
                    if values.isDirectory == true { continue }
                    if let record = ObservedFile(path: url.path) { fresh[record.identity] = record }
                }
                if let scanError { throw scanError }
            }
            if mustRebaseline {
                snapshot = fresh; pending.removeAll(); mustRebaseline = false
                onStatus?("Наблюдение активно · \(settings.folders.count) папок · \(fresh.count) файлов. Снимок сверён без конвертации")
                return
            }
            let candidates = SnapshotDiff.candidates(old: snapshot, new: fresh, includeNew: settings.handleNewFiles)
            for candidate in candidates { pending[candidate.file.identity] = candidate }
            snapshot = fresh
            if !pending.isEmpty {
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settle() }
            }
        } catch {
            mustRebaseline = true; pending.removeAll()
            onStatus?("Наблюдение остановлено до безопасной сверки: \(error.localizedDescription)")
        }
    }
    private func settle() {
        for (id, observation) in pending {
            guard let current = ObservedFile(path: observation.file.path) else { pending.removeValue(forKey: id); continue }
            if current == observation.file {
                pending.removeValue(forKey: id)
                onObservation?(observation)
            } else if current.identity == observation.file.identity {
                pending[id] = Observation(file: current, previousPath: observation.previousPath)
            } else { pending.removeValue(forKey: id) }
        }
        if !pending.isEmpty { queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settle() } }
    }
}
