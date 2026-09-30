import Foundation
import Darwin

public final class Transaction {
    public let store: StateStore
    public let worker: WorkerClient
    public var checkpoint: (Job) throws -> Void
    public var fault: ((String) throws -> Void)?
    public init(store: StateStore, worker: WorkerClient, checkpoint: @escaping (Job) throws -> Void) {
        self.store = store; self.worker = worker; self.checkpoint = checkpoint
    }
    private func save(_ job: inout Job, state: JobState? = nil, progress: Double? = nil) throws {
        if let state { job.state = state }
        if let progress { job.progress = progress }
        job.updatedAt = Date()
        try checkpoint(job)
    }
    private func inspect(_ path: String, maxBytes: Int64, settings: Settings, cancel: Cancellation) throws -> ContentInfo {
        try worker.perform(WorkerRequest(action: "inspect", input: path, maxPixels: settings.maxPixels, maxBytes: maxBytes), timeout: settings.workerTimeout, cancellation: cancel)
    }
    private func ensureScope(_ job: Job, settings: Settings) throws {
        guard !settings.paused, settings.folders.contains(where: { SafeFiles.isWithin(job.sourcePath, root: $0.path) }),
              !settings.exclusions.contains(where: { SafeFiles.isWithin(job.sourcePath, root: $0) }) else {
            throw RenamorphError.message("Наблюдение приостановлено или файл больше не входит в разрешённую область")
        }
        try SafeFiles.checkVolume(job.sourcePath)
        let parent = URL(fileURLWithPath: job.sourcePath).deletingLastPathComponent().path
        guard access(job.sourcePath, R_OK) == 0, access(parent, W_OK | X_OK) == 0 else {
            throw RenamorphError.message("Нет отдельных прав на чтение источника и запись в его каталог")
        }
    }
    private func prepareWorkspace(_ job: inout Job) throws -> URL {
        if let path = job.workspacePath {
            try SafeFiles.validateAncestors(path)
            return URL(fileURLWithPath: path)
        }
        let workspace = URL(fileURLWithPath: job.sourcePath).deletingLastPathComponent().appendingPathComponent(".renamorph-work-" + job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        job.workspacePath = workspace.path
        try save(&job)
        return workspace
    }
    public func prepare(_ job: inout Job, settings: Settings, cancel: Cancellation) throws {
        try ensureScope(job, settings: settings)
        try cancel.check()
        guard job.approvedVersion == job.source else { throw RenamorphError.message("Нет решения для этой версии содержимого") }
        try SafeFiles.requireVersion(job.sourcePath, job.source)
        guard let sourceInfo = job.image else { throw RenamorphError.message("Нет проверенного формата входа") }
        try save(&job, state: .preparing, progress: 0.05)
        guard try store.backupUsage() + job.source.size <= settings.backupLimitBytes else {
            throw RenamorphError.message("Лимит резервного хранилища исчерпан. Старые оригиналы не удаляются автоматически; увеличьте лимит")
        }
        guard try SafeFiles.availableBytes(store.backups.path) > job.source.size else { throw RenamorphError.message("Недостаточно места для оригинала в резервном хранилище") }
        let workspace = try prepareWorkspace(&job)
        let activeCount = job.outputs.filter { $0.state != .cancelled }.count
        guard activeCount > 0 else { throw RenamorphError.message("Все результаты отменены") }
        let estimatedOutput: Int64
        if let media = sourceInfo.media {
            let pcm = media.duration * Double(max(media.audio?.sampleRate ?? 48000, 48000)) * Double(media.audio?.channels ?? 2) * 4
            estimatedOutput = max(job.source.size * 4, Int64(pcm * 2), 64 * 1024 * 1024)
        } else { estimatedOutput = Int64(sourceInfo.width) * Int64(sourceInfo.height) * 8 + 16 * 1024 * 1024 }
        guard try SafeFiles.availableBytes(workspace.path) > estimatedOutput * Int64(activeCount) + job.source.size else {
            throw RenamorphError.message("Недостаточно места для безопасной подготовки всех результатов")
        }
        let backup = store.backups.appendingPathComponent(job.id.uuidString + ".original").path
        job.backupPath = backup
        try save(&job)
        _ = try SafeFiles.copyExclusive(from: job.sourcePath, to: backup, expected: job.source)
        try SafeFiles.syncFile(backup)
        try fault?("afterBackup")
        for index in job.outputs.indices where job.outputs[index].state != .cancelled {
            try cancel.check()
            job.outputs[index].state = .preparing
            let stage = workspace.appendingPathComponent("result-\(index).tmp").path
            job.outputs[index].stagePath = stage
            try save(&job, state: .running, progress: 0.1 + 0.6 * Double(index) / Double(job.outputs.count))
            if sourceInfo.isCompatible(with: job.outputs[index].format) {
                _ = try SafeFiles.copyExclusive(from: backup, to: stage)
                job.outputs[index].engine = "Побайтовая копия оригинала"
            } else {
                let converted = try worker.perform(WorkerRequest(action: "convert", input: backup, output: stage, target: job.outputs[index].format, options: job.outputs[index].settings.options, maxPixels: settings.maxPixels, maxBytes: settings.maxInputBytes, maxOutputBytes: estimatedOutput), timeout: settings.workerTimeout, cancellation: cancel)
                let route = try Route.find(converted.format, job.outputs[index].format)
                job.outputs[index].engine = converted.media?.engineVersion ?? (route.needsFFmpeg ? MediaToolchain().version ?? route.engine : route.engine)
            }
            try save(&job, state: .validating)
            let actual = try inspect(stage, maxBytes: estimatedOutput, settings: settings, cancel: cancel)
            try ResultValidation.check(source: sourceInfo, output: actual, target: job.outputs[index].format, options: job.outputs[index].settings.options)
            var sourceStat = stat()
            guard lstat(job.sourcePath, &sourceStat) == 0 else { throw SafeFiles.error("Источник недоступен") }
            guard chmod(stage, sourceStat.st_mode & 0o777) == 0 else { throw SafeFiles.error("Не удалось сохранить права результата") }
            try SafeFiles.syncFile(stage)
            job.outputs[index].version = try SafeFiles.fingerprint(stage)
            job.outputs[index].state = .validated
            try save(&job)
        }
        try cancel.check()
        try SafeFiles.requireVersion(job.sourcePath, job.source)
        try save(&job, state: .prepared, progress: 0.8)
    }
    public func publish(_ job: inout Job, settings: Settings, cancel: Cancellation) throws {
        try ensureScope(job, settings: settings)
        try cancel.check()
        guard job.outputs.count <= 1 || job.groupPolicy == .prepareAll else {
            job.message = "Все результаты проверены. Выберите политику публикации группы в настройках и подтвердите продолжение"
            try save(&job, state: .prepared)
            return
        }
        try SafeFiles.requireVersion(job.sourcePath, job.source)
        let active = job.outputs.indices.filter { job.outputs[$0].state != .cancelled }
        guard !active.isEmpty else { throw RenamorphError.message("Нет активных результатов") }
        for index in active {
            let output = job.outputs[index]
            guard let stage = output.stagePath, let version = output.version else { throw RenamorphError.message("Нет подготовленного результата") }
            try SafeFiles.requireVersion(stage, version)
            if output.path != job.sourcePath && SafeFiles.exists(output.path) { throw RenamorphError.message("Целевое имя занято: \(output.path)") }
        }
        job.publicationStarted = true
        try save(&job, state: .publishing, progress: 0.85)
        try fault?("afterPublicationJournal")
        for index in active {
            let output = job.outputs[index]
            try SafeFiles.requireVersion(job.sourcePath, job.source)
            job.outputs[index].state = .publishing
            try save(&job)
            if output.path == job.sourcePath {
                try SafeFiles.swap(output.stagePath!, output.path)
                try fault?("afterSwap")
                let displaced = try SafeFiles.fingerprint(output.stagePath!)
                guard displaced.identity == job.source.identity, displaced.sameContent(as: job.source) else {
                    job.message = "Во время замены обнаружено конкурентное изменение. Вытесненная версия сохранена: \(output.stagePath!). Требуется ручное восстановление"
                    throw RenamorphError.message(job.message)
                }
            } else {
                try SafeFiles.moveExclusive(output.stagePath!, output.path)
            }
            let published = try SafeFiles.fingerprint(output.path)
            guard published.identity == output.version!.identity, published.sameContent(as: output.version!) else {
                throw RenamorphError.message("Опубликованный результат изменён другой программой; обе версии и журнал сохранены")
            }
            job.outputs[index].version = published
            job.outputs[index].state = .published
            try save(&job)
            try fault?("afterOutputPublished")
        }
        if !active.contains(where: { job.outputs[$0].path == job.sourcePath }) {
            try SafeFiles.requireVersion(job.sourcePath, job.source)
            let parked = URL(fileURLWithPath: job.workspacePath!).appendingPathComponent("renamed-original").path
            job.originalParkedPath = parked
            try save(&job)
            try SafeFiles.moveExclusive(job.sourcePath, parked)
            let moved = try SafeFiles.fingerprint(parked)
            guard moved.identity == job.source.identity, moved.sameContent(as: job.source) else {
                throw RenamorphError.message("Источник изменился при завершении группы. Перемещённая версия сохранена в рабочем каталоге")
            }
        }
        job.message = "Результат проверен. Оригинал сохранён в резерве."
        try save(&job, state: .succeeded, progress: 1)
    }
    private func requirePublished(_ output: OutputRecord) throws {
        guard let expected = output.version else { throw RenamorphError.message("Нет версии опубликованного результата") }
        let actual = try SafeFiles.fingerprint(output.path)
        guard actual == expected else { throw RenamorphError.message("Результат изменён или заменён: \(output.path). Новые данные оставлены без изменений") }
    }
    public func undo(_ job: inout Job) throws {
        guard job.state == .succeeded || job.state == .restoreConflict, !job.outputs.contains(where: { $0.state == .restored }) else {
            throw RenamorphError.message("Для прерванного восстановления используйте «Сохранить оригинал рядом»")
        }
        guard let backup = job.backupPath, SafeFiles.exists(backup), try SafeFiles.fingerprint(backup).sameContent(as: job.source) else {
            throw RenamorphError.message("Резерв отсутствует или повреждён. Запись истории не означает доступность оригинала")
        }
        let published = job.outputs.indices.filter { job.outputs[$0].state == .published }
        guard !published.isEmpty else { throw RenamorphError.message("Нет полностью опубликованных результатов для Undo") }
        for index in published { try requirePublished(job.outputs[index]); try SafeFiles.checkVolume(job.outputs[index].path) }
        let target = job.previousPath ?? job.sourcePath
        let resultAtTarget = published.first { job.outputs[$0].path == target }
        if SafeFiles.exists(target), resultAtTarget == nil { throw RenamorphError.message("Прежнее имя занято: \(target). Восстановление не перезаписывает чужие файлы") }
        let workspace = try prepareWorkspace(&job)
        let stage = workspace.appendingPathComponent("restore-" + UUID().uuidString).path
        _ = try SafeFiles.copyExclusive(from: backup, to: stage)
        job.restoreTarget = target; job.restoreStage = stage
        job.message = "Восстановление оригинальных байтов из резерва"
        try save(&job, state: .restoring)
        try fault?("afterRestoreJournal")
        if let index = resultAtTarget {
            try requirePublished(job.outputs[index])
            try SafeFiles.swap(stage, target)
            let displaced = try SafeFiles.fingerprint(stage)
            guard displaced.identity == job.outputs[index].version?.identity,
                  displaced.sameContent(as: job.outputs[index].version!) else { throw RenamorphError.message("Конкурентное изменение при Undo; вытесненный файл сохранён в \(stage)") }
            job.outputs[index].state = .restored
            try save(&job)
        } else {
            try SafeFiles.moveExclusive(stage, target)
        }
        try fault?("afterOriginalRestored")
        for index in published where index != resultAtTarget {
            try requirePublished(job.outputs[index])
            let parked = workspace.appendingPathComponent("undo-output-\(index)").path
            try SafeFiles.moveExclusive(job.outputs[index].path, parked)
            let moved = try SafeFiles.fingerprint(parked)
            guard moved.identity == job.outputs[index].version?.identity,
                  moved.sameContent(as: job.outputs[index].version!) else { throw RenamorphError.message("Конкурентная правка результата при Undo сохранена в \(parked)") }
            job.outputs[index].state = .restored
            try save(&job)
        }
        guard try SafeFiles.fingerprint(target).sameContent(as: job.source) else { throw RenamorphError.message("Восстановленный оригинал изменён другой программой") }
        job.message = "Оригинальные байты восстановлены: \(target)"
        try save(&job, state: .restored, progress: 1)
    }
    public func exportOriginal(_ job: inout Job) throws -> String {
        guard let backup = job.backupPath, try SafeFiles.fingerprint(backup).sameContent(as: job.source) else { throw RenamorphError.message("Оригинал в резерве отсутствует или повреждён") }
        let original = URL(fileURLWithPath: job.previousPath ?? job.sourcePath)
        var parent = original.deletingLastPathComponent()
        if !SafeFiles.exists(parent.path) {
            parent = store.directory.appendingPathComponent("Recovered", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try SafeFiles.checkVolume(parent.path)
        let destination = parent.appendingPathComponent(original.deletingPathExtension().lastPathComponent + ".recovered-" + UUID().uuidString.prefix(8)).appendingPathExtension(job.image?.format.rawValue ?? "original")
        _ = try SafeFiles.copyExclusive(from: backup, to: destination.path)
        job.message = "Копия оригинала сохранена: \(destination.path). Остальные файлы и журнал сохранены для сверки"
        try save(&job)
        return destination.path
    }
    public func discardUnpublishedOutputs(_ job: inout Job) throws {
        guard !job.publicationStarted, let workspace = job.workspacePath else { return }
        let expected = URL(fileURLWithPath: job.sourcePath).deletingLastPathComponent().appendingPathComponent(".renamorph-work-" + job.id.uuidString)
        guard workspace == expected.path else { throw RenamorphError.message("Рабочий каталог не совпадает с журналом; данные оставлены для сверки") }
        try SafeFiles.validateAncestors(workspace)
        for index in job.outputs.indices {
            let outputPath = expected.appendingPathComponent("result-\(index).tmp").path
            guard job.outputs[index].stagePath == outputPath else { continue }
            if SafeFiles.exists(outputPath) { try FileManager.default.removeItem(atPath: outputPath) }
            job.outputs[index].stagePath = nil
            job.outputs[index].version = nil
            job.outputs[index].state = .cancelled
        }
        if try FileManager.default.contentsOfDirectory(atPath: workspace).isEmpty {
            try FileManager.default.removeItem(atPath: workspace)
            job.workspacePath = nil
        }
        try save(&job)
    }
}
