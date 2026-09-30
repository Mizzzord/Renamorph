import Testing
import Foundation
import ImageIO
import CoreGraphics
import Darwin
@testable import RenamorphCore

@Suite(.serialized)
final class CoreTests {
    var root: URL!
    var folder: URL!
    var store: StateStore!
    var worker: WorkerClient!
    var recoveryProbe: URL!
    var settings: Settings!
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test-artifacts/renamorph-test-" + UUID().uuidString)
        folder = root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try StateStore(directory: root.appendingPathComponent("state"))
        let binary = ProcessInfo.processInfo.environment["RENAMORPH_WORKER"] ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/RenamorphWorker").path
        worker = WorkerClient(executable: URL(fileURLWithPath: binary))
        recoveryProbe = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RENAMORPH_RECOVERY_PROBE"] ?? worker.executable.deletingLastPathComponent().appendingPathComponent("RenamorphRecoveryProbe").path)
        expectTrue(worker.available, "Build RenamorphWorker before tests")
        settings = Settings(); settings.folders = [WatchFolder(url: folder)]; settings.groupPolicy = .prepareAll
        settings.options.alpha = .white
    }
    deinit {
        store = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    func fixture(_ path: URL, format: FileFormat = .png, alpha: Bool = false, orientation: Int = 1, frames: Int = 1) throws {
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128, space: color, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: alpha ? 0.5 : 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let destination = try requireValue(CGImageDestinationCreateWithURL(path as CFURL, format.uti as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary) }
        expectTrue(CGImageDestinationFinalize(destination))
    }
    func inspect(_ path: String) throws -> ContentInfo {
        try worker.perform(WorkerRequest(action: "inspect", input: path), timeout: 15, cancellation: Cancellation())
    }
    func makeJob(_ suffix: String = "jpg", format: FileFormat = .png, alpha: Bool = false) throws -> Job {
        let original = folder.appendingPathComponent("photo." + format.rawValue)
        try fixture(original, format: format, alpha: alpha)
        let current = folder.appendingPathComponent("photo." + suffix)
        if original != current { try FileManager.default.moveItem(at: original, to: current) }
        let version = try SafeFiles.fingerprint(current.path)
        var job = Job(sourcePath: current.path, previousPath: original.path, source: version, trigger: "test rename")
        job.image = try inspect(current.path); job.approvedVersion = version; job.groupPolicy = .prepareAll
        for (target, path) in try RenameRequest.parse(path: current.path).targets {
            let rule = try settings.effective(source: format, target: target)
            job.outputs.append(OutputRecord(path: path, format: target, settings: rule, operation: "test", losses: "test"))
        }
        return job
    }
    func transaction(_ job: Job) throws -> Transaction {
        var state = PersistentState(); state.settings = settings; state.jobs = [job]; try store.save(state)
        return Transaction(store: store, worker: worker) { value in state.jobs = [value]; try self.store.save(state) }
    }
    @Test func testEveryDeclaredRouteThroughRealWorker() throws {
        for route in Route.all.filter({ $0.source.family == .raster }) {
            let input = folder.appendingPathComponent(route.id + ".wrong")
            let output = folder.appendingPathComponent(route.id + ".out")
            if route.source == .webp {
                let png = folder.appendingPathComponent(route.id + ".png")
                try fixture(png)
                _ = try worker.perform(WorkerRequest(action: "convert", input: png.path, output: input.path, target: .webp), timeout: 20, cancellation: Cancellation())
            } else { try fixture(input, format: route.source) }
            expectEqual(try inspect(input.path).format, route.source)
            var options = ConversionOptions(); options.alpha = .white
            _ = try worker.perform(WorkerRequest(action: "convert", input: input.path, output: output.path, target: route.target, options: options), timeout: 20, cancellation: Cancellation())
            let actual = try inspect(output.path)
            try ResultValidation.check(source: inspect(input.path), output: actual, target: route.target, options: options)
            expectEqual(actual.format, route.target, route.id)
            expectEqual(actual.width, 32); expectEqual(actual.height, 24)
        }
        expectEqual(Route.all.filter { $0.source.family == .raster }.count, 49)
    }
    @Test func testNewRasterTargetsPreserveTransparencyAndUndo() throws {
        for target in [FileFormat.heic, .avif] {
            var job = try makeJob(target.rawValue, alpha: true)
            let tx = try transaction(job)
            try tx.prepare(&job, settings: settings, cancel: Cancellation())
            try tx.publish(&job, settings: settings, cancel: Cancellation())
            expectEqual(job.state, .succeeded)
            let result = try inspect(job.sourcePath)
            expectEqual(result.format, target); expectTrue(result.hasAlpha)
            let encoded = try requireValue(CGImageSourceCreateWithURL(URL(fileURLWithPath: job.sourcePath) as CFURL, nil))
            let decoded = try requireValue(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            let color = try requireValue(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try requireValue(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 32, height: 24))
            let pixels = try requireValue(context.data).assumingMemoryBound(to: UInt8.self)
            expectTrue(abs(Int(pixels[3]) - 128) <= 3, "\(target.title): прозрачность пикселя должна сохраниться")
            try tx.undo(&job)
            expectEqual(try SafeFiles.fingerprint(job.previousPath!).digest, job.source.digest)
        }
    }
    @Test func testRenameHEICToJPEGAndExactUndo() throws {
        var job = try makeJob("jpg", format: .heic)
        let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectEqual(job.state, .succeeded)
        expectEqual(try inspect(job.sourcePath).format, .jpeg)
        expectEqual(try SafeFiles.fingerprint(job.backupPath!).digest, job.source.digest)
        try tx.undo(&job)
        expectEqual(job.state, .restored)
        expectEqual(try SafeFiles.fingerprint(job.previousPath!).digest, job.source.digest)
        expectFalse(SafeFiles.exists(job.sourcePath))
    }
    @Test func testUnknownAndRepeatedGroupExtensions() throws {
        let request = try RenameRequest.parse(path: "/tmp/photo.png,png,jpeg,jpg,tif")
        expectEqual(request.targets.map(\.format), [.png, .jpeg, .tiff])
        expectEqual(request.duplicateCount, 2)
        expectThrows(try RenameRequest.parse(path: "/tmp/photo.png,unknown"))
        expectThrows(try RenameRequest.parse(path: "/tmp/photo.png,"))
    }
    @Test func testAliasesAndBasenameDoNotBecomeCandidates() throws {
        let old = folder.appendingPathComponent("first.jpg")
        try fixture(old, format: .jpeg)
        let before = ObservedFile(path: old.path)!
        let renamed = folder.appendingPathComponent("second.jpg")
        try FileManager.default.moveItem(at: old, to: renamed)
        let after = ObservedFile(path: renamed.path)!
        expectTrue(SnapshotDiff.candidates(old: [before.identity: before], new: [after.identity: after], includeNew: false).isEmpty)
        expectEqual(FileFormat.from(extension: "JPEG"), .jpeg)
        expectEqual(FileFormat.from(extension: "tif"), .tiff)
        expectEqual(FileFormat.from(extension: "heif"), .heic)
        expectTrue(SnapshotDiff.candidates(old: [:], new: [after.identity: after], includeNew: false).isEmpty)
        expectEqual(SnapshotDiff.candidates(old: [:], new: [after.identity: after], includeNew: true).count, 1)
    }
    @Test func testRulesResolvePriorityAndRejectConflict() throws {
        settings.defaultAction = .automatic
        settings.rules = [PairRule(source: .png, target: .jpeg, action: .ask, options: .init())]
        expectEqual(try settings.effective(source: .png, target: .jpeg).action, .ask)
        expectEqual(try settings.effective(source: .heic, target: .jpeg).action, .automatic)
        settings.rules.append(settings.rules[0])
        expectThrows(try settings.effective(source: .png, target: .jpeg))
    }
    @Test func testVersionChangeBeforePreparationPreservesNewBytes() throws {
        var job = try makeJob()
        let tx = try transaction(job)
        try Data("new user edit".utf8).write(to: URL(fileURLWithPath: job.sourcePath))
        let edited = try Data(contentsOf: URL(fileURLWithPath: job.sourcePath))
        expectThrows(try tx.prepare(&job, settings: settings, cancel: Cancellation()))
        expectEqual(try Data(contentsOf: URL(fileURLWithPath: job.sourcePath)), edited)
    }
    @Test func testVersionChangeAfterPreparationBlocksPublication() throws {
        var job = try makeJob(); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try Data("modified after approval".utf8).write(to: URL(fileURLWithPath: job.sourcePath))
        expectThrows(try tx.publish(&job, settings: settings, cancel: Cancellation()))
        expectEqual(try String(contentsOfFile: job.sourcePath), "modified after approval")
        expectEqual(try SafeFiles.fingerprint(job.backupPath!).digest, job.source.digest)
    }
    @Test func testReplacedSourceSameBytesStillRejected() throws {
        var job = try makeJob(); let tx = try transaction(job)
        let data = try Data(contentsOf: URL(fileURLWithPath: job.sourcePath))
        try data.write(to: URL(fileURLWithPath: job.sourcePath), options: .atomic)
        expectThrows(try tx.prepare(&job, settings: settings, cancel: Cancellation()))
        expectEqual(try Data(contentsOf: URL(fileURLWithPath: job.sourcePath)), data)
    }
    @Test func testMultiOutputUsesOriginalForEveryBranch() throws {
        var job = try makeJob("png,jpg,tiff"); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        expectEqual(try SafeFiles.fingerprint(job.outputs[0].stagePath!).digest, job.source.digest)
        try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectEqual(job.state, .succeeded)
        expectFalse(SafeFiles.exists(job.sourcePath))
        for output in job.outputs { expectEqual(try inspect(output.path).format, output.format); expectEqual(output.state, .published) }
        try tx.undo(&job)
        expectEqual(try SafeFiles.fingerprint(job.previousPath!).digest, job.source.digest)
        expectFalse(SafeFiles.exists(job.outputs[1].path))
    }
    @Test func testUnagreedGroupStopsBeforePublishing() throws {
        var job = try makeJob("jpg,tiff"); job.groupPolicy = .undecided
        let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation()); try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectEqual(job.state, .prepared)
        expectFalse(job.publicationStarted)
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectFalse(SafeFiles.exists(job.outputs[0].path))
    }
    @Test func testCancelledBranchIsNeverPublished() throws {
        var job = try makeJob("jpg,tiff"); job.outputs[1].state = .cancelled
        let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation()); try tx.publish(&job, settings: settings, cancel: Cancellation())
        expectTrue(SafeFiles.exists(job.outputs[0].path)); expectFalse(SafeFiles.exists(job.outputs[1].path))
        expectEqual(job.outputs[1].state, .cancelled)
    }
    @Test func testConflictPreservesForeignFileAndSource() throws {
        var job = try makeJob("jpg,tiff"); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try Data("unrelated user data".utf8).write(to: URL(fileURLWithPath: job.outputs[1].path))
        expectThrows(try tx.publish(&job, settings: settings, cancel: Cancellation()))
        expectFalse(job.publicationStarted)
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectEqual(try String(contentsOfFile: job.outputs[1].path), "unrelated user data")
        expectFalse(SafeFiles.exists(job.outputs[0].path))
    }
    @Test func testBackupQuotaStopsBeforeSourceMutation() throws {
        var job = try makeJob(); settings.backupLimitBytes = 1; let tx = try transaction(job)
        expectThrows(try tx.prepare(&job, settings: settings, cancel: Cancellation()))
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectEqual(try store.backupUsage(), 0)
    }
    @Test func testCancelledPreparationPreservesSource() throws {
        var job = try makeJob(); let tx = try transaction(job); let cancellation = Cancellation(); cancellation.cancel()
        expectThrows(try tx.prepare(&job, settings: settings, cancel: cancellation))
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
    }
    @Test func testUndoConflictPreservesManualEdit() throws {
        var job = try makeJob(); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation()); try tx.publish(&job, settings: settings, cancel: Cancellation())
        try Data("manual edit".utf8).write(to: URL(fileURLWithPath: job.sourcePath))
        expectThrows(try tx.undo(&job))
        expectEqual(try String(contentsOfFile: job.sourcePath), "manual edit")
        expectEqual(try SafeFiles.fingerprint(job.backupPath!).digest, job.source.digest)
    }
    @Test func testUndoNameConflictAndMissingBackup() throws {
        var job = try makeJob(); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation()); try tx.publish(&job, settings: settings, cancel: Cancellation())
        try Data("occupied old name".utf8).write(to: URL(fileURLWithPath: job.previousPath!))
        expectThrows(try tx.undo(&job))
        try FileManager.default.removeItem(atPath: job.backupPath!)
        expectThrows(try tx.undo(&job))
        expectEqual(try String(contentsOfFile: job.previousPath!), "occupied old name")
    }
    @Test func testInterruptedPublicationLeavesDurableRecoveryEvidence() throws {
        var job = try makeJob(); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        tx.fault = { if $0 == "afterSwap" { throw RenamorphError.message("simulated process stop") } }
        expectThrows(try tx.publish(&job, settings: settings, cancel: Cancellation()))
        let saved = try store.load().jobs[0]
        expectEqual(saved.state, .publishing)
        expectTrue(saved.publicationStarted)
        expectEqual(try inspect(saved.sourcePath).format, .jpeg)
        expectEqual(try SafeFiles.fingerprint(saved.outputs[0].stagePath!).digest, saved.source.digest)
        expectEqual(try SafeFiles.fingerprint(saved.backupPath!).digest, saved.source.digest)
        let recovered = try tx.exportOriginal(&job)
        expectEqual(try SafeFiles.fingerprint(recovered).digest, saved.source.digest)
        expectEqual(try inspect(saved.sourcePath).format, .jpeg)
    }
    @Test func testGroupInterruptionKeepsSourceAndPartialResult() throws {
        var job = try makeJob("jpg,tiff"); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        tx.fault = { if $0 == "afterOutputPublished" { throw RenamorphError.message("simulated stop") } }
        expectThrows(try tx.publish(&job, settings: settings, cancel: Cancellation()))
        expectTrue(SafeFiles.exists(job.outputs[0].path)); expectFalse(SafeFiles.exists(job.outputs[1].path))
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectEqual(try store.load().jobs[0].state, .publishing)
    }
    @Test func testSymlinkAndHardLinkRejected() throws {
        let original = folder.appendingPathComponent("original.png"); try fixture(original)
        let symlink = folder.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        expectThrows(try SafeFiles.fingerprint(symlink.path))
        let hard = folder.appendingPathComponent("hard.jpg")
        expectEqual(link(original.path, hard.path), 0)
        expectThrows(try SafeFiles.fingerprint(hard.path))
        expectThrows(try SafeFiles.fingerprint(original.path))
    }
    @Test func testCorruptAndMultiFrameInputRejected() throws {
        let corrupt = folder.appendingPathComponent("bad.jpg")
        try Data([0xff, 0xd8, 0xff, 0x00, 0x12]).write(to: corrupt)
        expectThrows(try inspect(corrupt.path))
        let multi = folder.appendingPathComponent("multi.jpg")
        try fixture(multi, format: .tiff, frames: 2)
        expectThrows(try inspect(multi.path))
    }
    @Test func testAlphaNeedsExplicitPolicyAndPixelsAreLimited() throws {
        let input = folder.appendingPathComponent("alpha.jpg"); try fixture(input, alpha: true)
        let output = folder.appendingPathComponent("output.tmp")
        expectThrows(try worker.perform(WorkerRequest(action: "convert", input: input.path, output: output.path, target: .jpeg), timeout: 10, cancellation: Cancellation()))
        expectFalse(SafeFiles.exists(output.path))
        expectThrows(try worker.perform(WorkerRequest(action: "inspect", input: input.path, maxPixels: 4), timeout: 10, cancellation: Cancellation()))
    }
    @Test func testOrientationIsAppliedAndMetadataRemoved() throws {
        let input = folder.appendingPathComponent("rotated.wrong"); try fixture(input, format: .jpeg, orientation: 6)
        let output = folder.appendingPathComponent("output.tmp")
        _ = try worker.perform(WorkerRequest(action: "convert", input: input.path, output: output.path, target: .png), timeout: 10, cancellation: Cancellation())
        let info = try inspect(output.path)
        expectEqual(info.width, 24); expectEqual(info.height, 32); expectEqual(info.orientation, 1)
    }
    @Test func testJournalRoundTripAndSecondInstanceLock() throws {
        let job = try makeJob(); var state = PersistentState(); state.settings = settings; state.jobs = [job]
        try store.save(state)
        expectEqual(try store.load().jobs[0].source, job.source)
        expectEqual(try store.load().settings, settings)
        expectThrows(try StateStore(directory: store.directory))
    }
    @Test func testWorkerMissingAndCrashesReturnErrors() throws {
        let input = folder.appendingPathComponent("input.png"); try fixture(input)
        let missing = WorkerClient(executable: root.appendingPathComponent("missing-worker"))
        expectThrows(try missing.perform(WorkerRequest(action: "inspect", input: input.path), timeout: 1, cancellation: Cancellation()))
        let crash = WorkerClient(executable: URL(fileURLWithPath: "/usr/bin/false"))
        expectThrows(try crash.perform(WorkerRequest(action: "inspect", input: input.path), timeout: 1, cancellation: Cancellation()))
    }
    @Test func testLiveWatcherDetectsRenameAndExcludesFolder() throws {
        let original = folder.appendingPathComponent("live.png"); try fixture(original)
        let excluded = folder.appendingPathComponent("excluded"); try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false)
        let ignored = excluded.appendingPathComponent("ignored.png"); try fixture(ignored)
        settings.exclusions = [excluded.path]
        let baseline = DispatchSemaphore(value: 0), renamed = DispatchSemaphore(value: 0)
        let watcher = FolderWatcher()
        var baselineDone = false
        watcher.onStatus = { status in if status.contains("Снимок сверён"), !baselineDone { baselineDone = true; baseline.signal() } }
        watcher.onObservation = { observation in
            expectFalse(observation.file.path.contains("excluded"))
            expectEqual(observation.previousPath, original.path)
            if observation.file.path.hasSuffix("live.jpg") { renamed.signal() }
        }
        watcher.configure(settings)
        expectEqual(baseline.wait(timeout: .now() + 5), .success)
        try FileManager.default.moveItem(at: ignored, to: excluded.appendingPathComponent("ignored.jpg"))
        try FileManager.default.moveItem(at: original, to: folder.appendingPathComponent("live.jpg"))
        expectEqual(renamed.wait(timeout: .now() + 8), .success)
        watcher.configure(Settings())
    }
    @Test func testSIGKILLDuringPublicationBecomesRecoveryOnRestart() throws {
        let job = try makeJob()
        var state = PersistentState(); state.settings = settings; state.jobs = [job]
        try store.save(state)
        let directory = store.directory
        store = nil
        let process = Process()
        process.executableURL = recoveryProbe
        process.arguments = [directory.path, worker.executable.path, "afterSwap"]
        try process.run(); process.waitUntilExit()
        expectEqual(process.terminationReason, .uncaughtSignal)
        expectEqual(process.terminationStatus, SIGKILL)
        let coordinator = try Coordinator(directory: directory, workerURL: worker.executable)
        let changed = DispatchSemaphore(value: 0)
        coordinator.onChange = { state in
            if state.jobs[0].state == .needsRecovery { changed.signal() }
        }
        coordinator.start()
        expectEqual(changed.wait(timeout: .now() + 3), .success)
        let recovered = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        expectEqual(recovered.jobs[0].state, .needsRecovery)
        expectEqual(try SafeFiles.fingerprint(recovered.jobs[0].backupPath!).digest, job.source.digest)
        expectEqual(try SafeFiles.fingerprint(recovered.jobs[0].outputs[0].stagePath!).digest, job.source.digest)
        expectEqual(try inspect(job.sourcePath).format, .jpeg)
        coordinator.watcher.configure(Settings())
    }
    @Test func testWorkerCancellationKillsProcessGroup() throws {
        let probe = WorkerClient(executable: recoveryProbe)
        let pidFile = folder.appendingPathComponent("pids")
        let token = Cancellation()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                _ = try probe.perform(WorkerRequest(action: "hang", input: pidFile.path), timeout: 10, cancellation: token)
                Issue.record("Cancelled worker unexpectedly succeeded")
            } catch {}
            finished.signal()
        }
        let deadline = Date().addingTimeInterval(3)
        while !SafeFiles.exists(pidFile.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let pids = try String(contentsOf: pidFile).split(separator: " ").compactMap { Int32($0) }
        expectEqual(pids.count, 2)
        token.cancel()
        expectEqual(finished.wait(timeout: .now() + 3), .success)
        for pid in pids {
            let end = Date().addingTimeInterval(3)
            while kill(pid, 0) == 0, Date() < end { Thread.sleep(forTimeInterval: 0.02) }
            expectEqual(kill(pid, 0), -1)
            expectEqual(errno, ESRCH)
        }
    }
    @Test func testWorkerTimeoutStopsHungEngine() throws {
        let probe = WorkerClient(executable: recoveryProbe)
        let start = Date()
        expectThrows(try probe.perform(WorkerRequest(action: "hang", input: folder.appendingPathComponent("pids").path), timeout: 0.2, cancellation: Cancellation()))
        expectTrue(Date().timeIntervalSince(start) < 3)
    }
    @Test func testWritePermissionFailurePreservesSource() throws {
        var job = try makeJob(); let tx = try transaction(job)
        expectEqual(chmod(folder.path, 0o500), 0)
        defer { chmod(folder.path, 0o700) }
        expectThrows(try tx.prepare(&job, settings: settings, cancel: Cancellation()))
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectFalse(job.publicationStarted)
    }
    @Test func testWatcherRapidRenameAndRescanDoNotMultiplyRequests() throws {
        let original = folder.appendingPathComponent("rapid.png"); try fixture(original)
        let watcher = FolderWatcher(), baseline = DispatchSemaphore(value: 0), changed = DispatchSemaphore(value: 0)
        watcher.onStatus = { if $0.contains("Снимок сверён") { baseline.signal() } }
        watcher.onObservation = { observation in
            expectTrue(observation.file.path.hasSuffix("rapid.tiff"))
            changed.signal()
        }
        watcher.configure(settings)
        expectEqual(baseline.wait(timeout: .now() + 3), .success)
        let intermediate = folder.appendingPathComponent("rapid.jpg"), final = folder.appendingPathComponent("rapid.tiff")
        try FileManager.default.moveItem(at: original, to: intermediate)
        try FileManager.default.moveItem(at: intermediate, to: final)
        expectEqual(changed.wait(timeout: .now() + 5), .success)
        watcher.rescan()
        expectEqual(baseline.wait(timeout: .now() + 3), .success)
        expectEqual(changed.wait(timeout: .now() + 1), .timedOut)
        watcher.configure(Settings())
    }
    @Test func testCoordinatorAutomaticRuleCompletesRealRename() throws {
        let original = folder.appendingPathComponent("auto.heic"); try fixture(original, format: .heic)
        let directory = root.appendingPathComponent("coordinator-state")
        let coordinator = try Coordinator(directory: directory, workerURL: worker.executable)
        let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        coordinator.onDiagnostic = { if $0.contains("Снимок сверён") { ready.signal() } }
        coordinator.onChange = { if $0.jobs.last?.state == .succeeded { done.signal() } }
        settings.rules = [PairRule(source: .heic, target: .jpeg, action: .automatic, options: ConversionOptions())]
        coordinator.updateSettings(settings)
        expectEqual(ready.wait(timeout: .now() + 3), .success)
        let target = folder.appendingPathComponent("auto.jpg")
        try FileManager.default.moveItem(at: original, to: target)
        expectEqual(done.wait(timeout: .now() + 8), .success)
        expectEqual(try inspect(target.path).format, .jpeg)
        let state = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        expectEqual(state.jobs.count, 1)
        expectEqual(state.jobs[0].outputs[0].settings.action, .automatic)
        coordinator.watcher.configure(Settings())
    }
    @Test func testCancellationReleasesOnlyUnpublishedWorkingResults() throws {
        var job = try makeJob("jpg,tiff"); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        let workspace = job.workspacePath!
        job.state = .cancelled
        try tx.discardUnpublishedOutputs(&job)
        expectFalse(SafeFiles.exists(workspace))
        expectEqual(try SafeFiles.fingerprint(job.sourcePath).digest, job.source.digest)
        expectEqual(try SafeFiles.fingerprint(job.backupPath!).digest, job.source.digest)
        expectTrue(job.outputs.allSatisfy { $0.state == .cancelled && $0.stagePath == nil })
    }
    @Test func testOriginalCanBeExportedAfterItsFolderMoved() throws {
        var job = try makeJob(); let tx = try transaction(job)
        try tx.prepare(&job, settings: settings, cancel: Cancellation())
        try tx.publish(&job, settings: settings, cancel: Cancellation())
        let newFolder = root.appendingPathComponent("moved-root")
        try FileManager.default.moveItem(at: folder, to: newFolder)
        let extracted = try tx.exportOriginal(&job)
        expectTrue(extracted.hasPrefix(store.directory.appendingPathComponent("Recovered").path))
        expectEqual(try SafeFiles.fingerprint(extracted).digest, job.source.digest)
        expectEqual(try inspect(newFolder.appendingPathComponent("photo.jpg").path).format, .jpeg)
    }
    @Test func testUntrustedWorkerDimensionsAreRejectedBeforeArithmetic() throws {
        let probe = WorkerClient(executable: recoveryProbe)
        expectThrows(try probe.perform(WorkerRequest(action: "invalid-response", input: folder.path), timeout: 3, cancellation: Cancellation()))
    }
}
