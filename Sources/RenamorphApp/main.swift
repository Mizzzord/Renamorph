import AppKit
import SwiftUI
import RenamorphCore

final class AppModel: ObservableObject {
    @Published var state = PersistentState()
    @Published var diagnostic = "Запуск наблюдателя…"
    let coordinator: Coordinator
    var onUpdate: (() -> Void)?
    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        coordinator.onChange = { [weak self] state in DispatchQueue.main.async { self?.state = state; self?.onUpdate?() } }
        coordinator.onDiagnostic = { [weak self] status in DispatchQueue.main.async { self?.diagnostic = status } }
    }
    func modify(_ change: (inout RenamorphCore.Settings) -> Void) {
        var settings = state.settings; change(&settings); coordinator.updateSettings(settings)
    }
    func chooseFolder(exclusion: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = exclusion ? "Исключить" : "Наблюдать"
        if panel.runModal() == .OK, let url = panel.url {
            modify { settings in
                if exclusion { if !settings.exclusions.contains(url.path) { settings.exclusions.append(url.path) } }
                else if !settings.folders.contains(where: { $0.path == url.path }) { settings.folders.append(WatchFolder(url: url)) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            NSApplication.shared.applicationIconImage = NSImage(contentsOf: icon)
        }
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "О программе Renamorph", action: #selector(showAbout), keyEquivalent: "").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Открыть Renamorph", action: #selector(showWindow), keyEquivalent: "o").target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Завершить Renamorph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
        let args = CommandLine.arguments
        let customIndex = args.firstIndex(of: "--data-dir")
        let directory: URL
        if let i = customIndex, args.indices.contains(i + 1) { directory = URL(fileURLWithPath: args[i + 1]) }
        else { directory = AppDataDirectory.resolve(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }
        let bundleWorker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RenamorphWorker")
        let worker = FileManager.default.isExecutableFile(atPath: bundleWorker.path) ? bundleWorker : URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("RenamorphWorker")
        do {
            let coordinator = try Coordinator(directory: directory, workerURL: worker)
            let model = AppModel(coordinator: coordinator); self.model = model
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Renamorph"; window.minSize = NSSize(width: 920, height: 640)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainView(model: model))
            window.center()
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Renamorph")
            statusItem.button?.toolTip = "Renamorph — локальное преобразование файлов"
            model.onUpdate = { [weak self] in self?.updateMenu() }
            updateMenu(); coordinator.start()
            if !args.contains("--background") { showWindow() }
        } catch {
            let alert = NSAlert(); alert.messageText = "Renamorph не запущен"; alert.informativeText = error.localizedDescription; alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }
    func updateMenu() {
        guard let model else { return }
        let count = model.state.jobs.filter { $0.state == .awaiting }.count
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Открыть Renamorph", action: #selector(showWindow), keyEquivalent: "o"); open.target = self
        menu.addItem(withTitle: "Ожидают решения: \(count)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: model.state.settings.paused ? "Продолжить наблюдение" : "Приостановить наблюдение", action: #selector(togglePause), keyEquivalent: ""); pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "О программе Renamorph", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Завершить Renamorph", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true) }
    @objc func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "Локальное преобразование файлов с резервом оригиналов.\n© 2026 Mizzzord · GPL-2.0-or-later\nFFmpeg / x264: GPL-2.0-or-later. Лицензии: Contents/Resources/ThirdParty.\nИсходники: github.com/Mizzzord/Renamorph/releases")])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func togglePause() { model?.modify { $0.paused.toggle() } }
    func applicationWillTerminate(_ notification: Notification) { model?.coordinator.cancelAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
