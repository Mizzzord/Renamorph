import Foundation

public final class Coordinator {
    private let queue = DispatchQueue(label: "local.renamorph.coordinator", qos: .userInitiated)
    private let tokenLock = NSLock()
    private var tokens: [UUID: Cancellation] = [:]
    private var state: PersistentState
    public let store: StateStore
    public let worker: WorkerClient
    public let watcher = FolderWatcher()
    public var onChange: ((PersistentState) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    public init(directory: URL, workerURL: URL) throws {
        store = try StateStore(directory: directory)
        worker = WorkerClient(executable: workerURL)
        state = try store.load()
        for i in state.jobs.indices {
            if state.jobs[i].state.isInFlight {
                if state.jobs[i].publicationStarted || state.jobs[i].state == .restoring {
                    state.jobs[i].state = .needsRecovery
                    state.jobs[i].message = "Приложение прервано во время публикации/восстановления. Никакие файлы автоматически не удалены. Сохраните оригинал рядом и сверьте рабочий каталог"
                } else {
                    state.jobs[i].state = .cancelled
                    state.jobs[i].message = "Подготовка прервана перезапуском. Оригинал и сохранённые рабочие данные оставлены без изменений"
                }
            }
        }
        try store.save(state)
        watcher.onObservation = { [weak self] event in self?.observe(event) }
        watcher.onStatus = { [weak self] status in self?.onDiagnostic?(status) }
        watcher.onRootMoved = { [weak self] id, path in
            guard let self else { return }
            self.queue.async {
                guard let i = self.state.settings.folders.firstIndex(where: { $0.id == id }) else { return }
                self.state.settings.folders[i].path = path
                do { try self.persist(); self.watcher.configure(self.state.settings) } catch { self.onDiagnostic?(error.localizedDescription) }
            }
        }
    }
    public func start() {
        queue.async { self.onChange?(self.state); self.watcher.configure(self.state.settings) }
    }
    private func persist() throws { try store.save(state); onChange?(state) }
    public func updateSettings(_ settings: Settings) {
        queue.async {
            do {
                try settings.validate()
                for folder in settings.folders { try SafeFiles.checkVolume(folder.path) }
                var proposed = settings
                if !proposed.exclusions.contains(self.store.directory.path) { proposed.exclusions.append(self.store.directory.path) }
                let watcherChanged = self.state.settings.folders != proposed.folders || self.state.settings.exclusions != proposed.exclusions || self.state.settings.paused != proposed.paused || self.state.settings.handleNewFiles != proposed.handleNewFiles
                var next = self.state
                next.settings = proposed
                try self.store.save(next)
                self.state = next
                self.onChange?(next)
                if watcherChanged { self.watcher.configure(proposed) }
            } catch { self.onDiagnostic?("Настройки не сохранены: \(error.localizedDescription)"); self.onChange?(self.state) }
        }
    }
    public func observe(_ observation: Observation) {
        queue.async { self.handle(observation) }
    }
    private func handle(_ observation: Observation) {
        let settings = state.settings, path = observation.file.path
        guard !settings.paused,
              settings.folders.contains(where: { SafeFiles.isWithin(path, root: $0.path) }),
              !settings.exclusions.contains(where: { SafeFiles.isWithin(path, root: $0) }),
              observation.previousPath != nil || settings.handleNewFiles else { return }
        var job: Job?
        let inspection = Cancellation()
        defer { if let id = job?.id { tokenLock.lock(); tokens.removeValue(forKey: id); tokenLock.unlock() } }
        do {
            try SafeFiles.checkVolume(path)
            guard ObservedFile(path: path) == observation.file else { return }
            let version = try SafeFiles.fingerprint(path, maxBytes: settings.maxInputBytes)
            guard !state.ownFiles.contains(where: { $0.path == path && $0.identity == version.identity && $0.digest == version.digest }),
                  !state.jobs.contains(where: { $0.sourcePath == path && $0.source == version && [.inspecting, .awaiting, .queued, .preparing, .running, .validating, .prepared, .publishing].contains($0.state) }) else { return }
            var candidate = Job(sourcePath: path, previousPath: observation.previousPath, source: version, trigger: observation.previousPath == nil ? "Новый файл (включён отдельной настройкой)" : "Изменение расширения известного файла")
            job = candidate
            candidate.state = .inspecting; candidate.message = "Определяем содержимое и проверяем декодирование"
            state.jobs.append(candidate); try persist()
            tokenLock.lock(); tokens[candidate.id] = inspection; tokenLock.unlock()
            let request = try RenameRequest.parse(path: path)
            let image = try worker.perform(WorkerRequest(action: "inspect", input: path, maxPixels: settings.maxPixels, maxBytes: settings.maxInputBytes), timeout: settings.workerTimeout, cancellation: inspection)
            try SafeFiles.requireVersion(path, version)
            if request.targets.count == 1, image.isCompatible(with: request.targets[0].format), request.targets[0].path == path {
                state.jobs.removeAll { $0.id == candidate.id }; try persist(); return
            }
            candidate.image = image; candidate.state = .awaiting; job = candidate
            for target in request.targets {
                let effective = try settings.effective(source: image.format, target: target.format)
                guard effective.action != .deny else { throw RenamorphError.message("Преобразование запрещено правилом \(image.format.title) → \(target.format.title)") }
                let route = image.isCompatible(with: target.format) ? nil : try Route.find(image.format, target.format)
                if route?.needsFFmpeg == true, !MediaToolchain().available { throw RenamorphError.message(MediaToolchain().description) }
                let plan = route != nil && image.format.isMedia ? try MediaPlan.resolve(image, target: target.format, options: effective.options) : nil
                candidate.outputs.append(OutputRecord(path: target.path, format: target.format, settings: effective,
                                                      operation: plan?.title ?? route?.operation ?? "Копия исходных байтов", losses: plan?.copyStreams == true ? "Сжатые потоки сохраняются без перекодирования. Теги и главы не переносятся." + (plan?.extractAudio == true ? " Видео исключается." : "") : (route?.losses ?? "Байты не меняются"), engine: image.media?.engineVersion ?? route?.engine))
            }
            candidate.groupPolicy = settings.groupPolicy
            candidate.message = request.duplicateCount > 0 ? "Повторяющиеся форматы объединены: \(request.duplicateCount)" : "Решение относится к показанной версии входа. \(image.summary)"
            let automatic = candidate.outputs.allSatisfy { $0.settings.action == .automatic }
            if automatic { candidate.approvedVersion = version; candidate.state = .queued }
            if let index = state.jobs.firstIndex(where: { $0.id == candidate.id }) { state.jobs[index] = candidate }
            try persist()
            tokenLock.lock(); tokens.removeValue(forKey: candidate.id); tokenLock.unlock()
            if automatic { enqueue(candidate.id) }
            job = nil
        } catch {
            if var job {
                job.state = inspection.isCancelled ? .cancelled : .unsupported; job.message = error.localizedDescription
                if let index = state.jobs.firstIndex(where: { $0.id == job.id }) { state.jobs[index] = job }
                else { state.jobs.append(job) }
                do { try persist() } catch { onDiagnostic?("Журнал недоступен: \(error.localizedDescription)") }
            } else { onDiagnostic?("Файл оставлен без изменений: \(error.localizedDescription)") }
        }
    }
    public func approve(_ id: UUID) {
        queue.async {
            guard let index = self.state.jobs.firstIndex(where: { $0.id == id }), self.state.jobs[index].state == .awaiting else { return }
            do {
                try SafeFiles.requireVersion(self.state.jobs[index].sourcePath, self.state.jobs[index].source)
                self.state.jobs[index].approvedVersion = self.state.jobs[index].source
                self.state.jobs[index].state = .queued
                try self.persist(); self.enqueue(id)
            } catch { self.state.jobs[index].state = .cancelled; self.state.jobs[index].message = error.localizedDescription; self.saveOrStop() }
        }
    }
    private func enqueue(_ id: UUID) {
        let token = Cancellation()
        tokenLock.lock(); tokens[id] = token; tokenLock.unlock()
        queue.async { self.execute(id, cancel: token) }
    }
    private func transaction() -> Transaction {
        Transaction(store: store, worker: worker) { job in
            guard let index = self.state.jobs.firstIndex(where: { $0.id == job.id }) else { throw RenamorphError.message("Операция отсутствует в журнале") }
            self.state.jobs[index] = job
            try self.persist()
        }
    }
    private func execute(_ id: UUID, cancel: Cancellation) {
        defer { tokenLock.lock(); tokens.removeValue(forKey: id); tokenLock.unlock() }
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].state == .queued else { return }
        var job = state.jobs[index]
        do {
            let tx = transaction()
            try tx.prepare(&job, settings: state.settings, cancel: cancel)
            try tx.publish(&job, settings: state.settings, cancel: cancel)
            rememberOutputs(job)
        } catch {
            job.state = job.publicationStarted ? .needsRecovery : (cancel.isCancelled ? .cancelled : .failed)
            job.message = error.localizedDescription
            job.updatedAt = Date()
            if !job.publicationStarted {
                do { try transaction().discardUnpublishedOutputs(&job) }
                catch { job.message += "; очистка временных результатов: " + error.localizedDescription }
            }
        }
        state.jobs[index] = job
        saveOrStop()
    }
    private func remember(_ path: String) {
        guard let version = try? SafeFiles.fingerprint(path) else { return }
        state.ownFiles.removeAll { $0.path == path }
        state.ownFiles.append(OwnFile(path: path, identity: version.identity, digest: version.digest))
    }
    private func rememberOutputs(_ job: Job) { for output in job.outputs where output.state == .published { remember(output.path) } }
    private func saveOrStop() {
        do { try persist() } catch {
            state.settings.paused = true
            watcher.configure(state.settings)
            onChange?(state)
            onDiagnostic?("Ошибка сохранения журнала; новые задания остановлены: \(error.localizedDescription)")
        }
    }
    public func cancel(_ id: UUID) {
        tokenLock.lock(); tokens[id]?.cancel(); tokenLock.unlock()
        queue.async {
            guard let index = self.state.jobs.firstIndex(where: { $0.id == id }), [.awaiting, .queued, .prepared].contains(self.state.jobs[index].state) else { return }
            var job = self.state.jobs[index]
            job.state = .cancelled
            job.message = "Отменено пользователем; исходные байты сохранены"
            do { try self.transaction().discardUnpublishedOutputs(&job) }
            catch { job.message += "; временные данные оставлены: " + error.localizedDescription }
            self.state.jobs[index] = job
            self.saveOrStop()
        }
    }
    public func cancelAll() { tokenLock.lock(); tokens.values.forEach { $0.cancel() }; tokenLock.unlock() }
    public func cancelOutput(_ id: UUID, outputID: UUID) {
        queue.async {
            guard let i = self.state.jobs.firstIndex(where: { $0.id == id }), [.awaiting, .prepared].contains(self.state.jobs[i].state),
                  let j = self.state.jobs[i].outputs.firstIndex(where: { $0.id == outputID }) else { return }
            self.state.jobs[i].outputs[j].state = .cancelled
            if self.state.jobs[i].outputs.allSatisfy({ $0.state == .cancelled }) { self.state.jobs[i].state = .cancelled }
            self.saveOrStop()
        }
    }
    public func publishPrepared(_ id: UUID) {
        queue.async {
            guard let i = self.state.jobs.firstIndex(where: { $0.id == id }), self.state.jobs[i].state == .prepared else { return }
            var job = self.state.jobs[i]
            do {
                job.groupPolicy = self.state.settings.groupPolicy
                try self.transaction().publish(&job, settings: self.state.settings, cancel: Cancellation())
                self.rememberOutputs(job)
            } catch { job.state = job.publicationStarted ? .needsRecovery : .failed; job.message = error.localizedDescription }
            self.state.jobs[i] = job; self.saveOrStop()
        }
    }
    public func undo(_ id: UUID) {
        queue.async {
            guard let i = self.state.jobs.firstIndex(where: { $0.id == id }) else { return }
            var job = self.state.jobs[i]
            do { try self.transaction().undo(&job); self.remember(job.restoreTarget ?? job.sourcePath) }
            catch { job.state = job.state == .restoring ? .needsRecovery : .restoreConflict; job.message = error.localizedDescription }
            self.state.jobs[i] = job; self.saveOrStop()
        }
    }
    public func exportOriginal(_ id: UUID) {
        queue.async {
            guard let i = self.state.jobs.firstIndex(where: { $0.id == id }) else { return }
            var job = self.state.jobs[i]
            do { let path = try self.transaction().exportOriginal(&job); self.remember(path) }
            catch { job.message = error.localizedDescription }
            self.state.jobs[i] = job; self.saveOrStop()
        }
    }
}
