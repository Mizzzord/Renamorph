import SwiftUI
import AppKit
import RenamorphCore

typealias ViewState<Value> = SwiftUI.State<Value>

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Обзор", queue = "Задания", folders = "Папки", formats = "Форматы", history = "История", settings = "Настройки"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "house.fill"
        case .queue: return "square.stack.3d.up.fill"
        case .folders: return "folder"
        case .formats: return "arrow.triangle.branch"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        }
    }
    var color: Color {
        switch self {
        case .overview: return .orange
        case .queue, .folders: return AppTheme.blue
        case .formats, .settings: return .gray
        case .history: return AppTheme.violet
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ViewState private var section: AppSection? = .overview
    @ViewState private var visibility: NavigationSplitViewVisibility = .all
    var selected: AppSection { section ?? .overview }
    var awaiting: Int { model.state.jobs.filter { $0.state == .awaiting }.count }
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 250)
        } detail: {
            VStack(spacing: 0) {
                header
                Rectangle().fill(AppTheme.border).frame(height: 1)
                if let issue = model.diagnosticIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                        .foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 32).padding(.top, 16)
                }
                ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch selected {
                            case .overview: OverviewView(model: model) { section = $0 }
                            case .queue: JobsView(model: model, history: false) { section = .settings }
                            case .folders: FoldersView(model: model)
                            case .formats: FormatsView(model: model)
                            case .history: JobsView(model: model, history: true) { section = .settings }
                            case .settings: SettingsView(model: model)
                            }
                        }.padding(32).frame(maxWidth: 1100, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                }.id(selected).scrollIndicators(.hidden)
            }.background(AppTheme.canvas)
        }
        .navigationSplitViewStyle(.balanced).background(AppTheme.canvas)
        .tint(AppTheme.accent).foregroundStyle(AppTheme.text)
        .preferredColorScheme(.dark).font(.system(size: 14))
        .toolbar(.hidden, for: .windowToolbar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $section) {
                ForEach(AppSection.allCases) { item in
                    HStack(spacing: 12) {
                        IconTile(symbol: item.symbol, color: item.color)
                        Text(item.rawValue).font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                        if item == .queue && awaiting > 0 {
                            Text("\(awaiting)").font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.text).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(AppTheme.separator, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(.vertical, 7).tag(item)
                        .listRowBackground(RoundedRectangle(cornerRadius: 12).fill(selected == item ? AppTheme.selection : .clear))
                        .listRowSeparator(.hidden).accessibilityIdentifier("navigation.\(item.id)")
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).padding(.horizontal, 8).padding(.top, 26)
            HStack(spacing: 8) {
                Text("Renamorph").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "LOCAL")
                    .font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(AppTheme.muted).padding(14)
                .overlay(Capsule().strokeBorder(AppTheme.separator)).padding(14)
        }.background(AppTheme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { visibility = visibility == .detailOnly ? .all : .detailOnly } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).foregroundStyle(AppTheme.muted)
                .accessibilityLabel("Показать или скрыть боковую панель").keyboardShortcut("s", modifiers: [.command, .control])
            Spacer(minLength: 8)
            Text(selected.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(AppTheme.secondary)
            if selected == .overview || selected == .folders {
                Button { model.chooseFolder() } label: { Image(systemName: "plus") }
                    .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Добавить папку")
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            } else if selected == .history {
                Button { NSWorkspace.shared.open(model.coordinator.store.directory) } label: { Image(systemName: "externaldrive") }
                    .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Хранилище")
            }
            Button { model.coordinator.watcher.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Сверить папки")
                .help(model.diagnostic)
            Button { model.modify { $0.paused.toggle() } } label: { Image(systemName: model.state.settings.paused ? "play.fill" : "pause.fill") }
                .buttonStyle(AppButtonStyle(kind: .quiet))
                .accessibilityLabel(model.state.settings.paused ? "Продолжить наблюдение" : "Приостановить наблюдение")
                .help(model.state.settings.paused ? "Продолжить наблюдение" : "Приостановить наблюдение")
        }.padding(.horizontal, 24).frame(height: 42)
    }
}
