import SwiftUI
import AppKit
import RenamorphCore

enum JobFilter: String, CaseIterable, Identifiable {
    case all = "Все", attention = "Нужен ответ", working = "В работе", completed = "Готово", problems = "Проблемы"
    var id: String { rawValue }
    func matches(_ job: Job) -> Bool {
        switch self {
        case .all: return true
        case .attention: return job.state.requiresAttention
        case .working: return job.state.isInFlight
        case .completed: return [.succeeded, .restored].contains(job.state)
        case .problems: return [.failed, .unsupported, .needsRecovery, .restoreConflict].contains(job.state)
        }
    }
}

struct JobsView: View {
    @ObservedObject var model: AppModel
    let history: Bool
    let openSettings: () -> Void
    @ViewState private var query = ""
    @ViewState private var filter: JobFilter = .all
    private var candidates: [Job] { model.state.jobs.reversed().filter { history || $0.state.appearsInQueue } }
    private var visible: [Job] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { job in
            filter.matches(job) && (term.isEmpty || [job.name, job.sourcePath, job.image?.format.title ?? "", job.outputs.map { $0.format.title }.joined(separator: " "), job.state.title, job.message]
                .contains { $0.localizedCaseInsensitiveContains(term) })
        }
    }
    private var filters: [JobFilter] { history ? [.all, .completed, .problems] : [.all, .attention, .working, .problems] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { filterPicker; AppSearchField(placeholder: "Поиск", text: $query).frame(width: 200) }
                VStack(alignment: .leading, spacing: 12) { filterPicker; AppSearchField(placeholder: "Поиск", text: $query) }
            }
            if visible.isEmpty {
                if !query.isEmpty || filter != .all {
                    EmptyState(symbol: "magnifyingglass", title: "Ничего не найдено") {
                        Button("Сбросить") { query = ""; filter = .all }.buttonStyle(AppButtonStyle())
                    }
                } else if history {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "Нет операций") { }
                } else if model.state.settings.folders.isEmpty {
                    EmptyState(symbol: "folder", title: "Нет папок") {
                        Button("Добавить папку") { model.chooseFolder() }.buttonStyle(AppButtonStyle())
                    }
                } else {
                    EmptyState(symbol: model.state.settings.paused ? "pause.circle" : "tray", title: model.state.settings.paused ? "На паузе" : "Нет заданий") {
                        if model.state.settings.paused {
                            Button("Продолжить") { model.modify { $0.paused = false } }.buttonStyle(AppButtonStyle())
                        }
                    }
                }
            }
            LazyVStack(spacing: 14) {
                ForEach(visible) { JobCard(job: $0, model: model, openSettings: openSettings) }
            }
        }
    }
    private var filterPicker: some View {
        Picker("Фильтр операций", selection: $filter) {
            ForEach(filters) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(minWidth: 310, maxWidth: .infinity)
    }
}

struct JobCard: View {
    let job: Job
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @ViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var backupExists: Bool { job.backupPath.map { SafeFiles.exists($0) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { identity; Spacer(minLength: 8); status }
                VStack(alignment: .leading, spacing: 12) { identity; status }
            }
            if job.state.isInFlight {
                ProgressView(value: job.progress).tint(AppTheme.accent)
            }
            if [.failed, .unsupported, .needsRecovery, .restoreConflict].contains(job.state) {
                Text(job.message).font(.system(size: 12)).foregroundStyle(AppTheme.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actions; Spacer(minLength: 8); detailsButton }
                VStack(alignment: .leading, spacing: 10) { actions; detailsButton }
            }
            if job.state == .prepared && model.state.settings.groupPolicy == .undecided {
                Button("Выбрать политику группы", action: openSettings).buttonStyle(AppButtonStyle())
            }
            if expanded { details }
        }.appSurface(padding: 18)
    }
    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: job.image?.format.family.symbol ?? "doc").font(.system(size: 18)).foregroundStyle(AppTheme.muted).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(job.name).font(.system(size: 14, weight: .medium)).lineLimit(2).textSelection(.enabled)
                HStack(spacing: 7) {
                    Text(job.image?.format.title ?? "Неизвестный вход")
                    if !job.outputs.isEmpty {
                        Image(systemName: "arrow.right").font(.system(size: 9)).accessibilityHidden(true)
                        Text(job.outputs.map { $0.format.title }.joined(separator: " · "))
                    }
                }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(AppTheme.muted)
            }
        }
    }
    private var status: some View { SmallBadge(title: job.state.title, color: job.state.tint, symbol: job.state.symbol) }
    @ViewBuilder private var actions: some View {
        if job.state == .awaiting {
            HStack(spacing: 8) {
                Button { model.coordinator.approve(job.id) } label: { Label("Преобразовать", systemImage: "arrow.triangle.2.circlepath") }.buttonStyle(AppButtonStyle(kind: .primary))
                Button("Отклонить") { model.coordinator.cancel(job.id) }.buttonStyle(AppButtonStyle())
            }
        } else if job.state == .prepared {
            HStack(spacing: 8) {
                Button("Опубликовать группу") { model.coordinator.publishPrepared(job.id) }.buttonStyle(AppButtonStyle(kind: .primary))
                    .disabled(model.state.settings.groupPolicy == .undecided)
                Button("Отменить") { model.coordinator.cancel(job.id) }.buttonStyle(AppButtonStyle())
            }
        } else if [.inspecting, .queued, .preparing, .running, .validating].contains(job.state) {
            Button("Отменить") { model.coordinator.cancel(job.id) }.buttonStyle(AppButtonStyle())
        }
        if [.succeeded, .restoreConflict].contains(job.state) {
            Button { model.coordinator.undo(job.id) } label: { Label("Восстановить оригинал", systemImage: "arrow.uturn.backward") }
                .buttonStyle(AppButtonStyle()).disabled(!backupExists)
        }
        if backupExists {
            Button("Сохранить оригинал рядом") { model.coordinator.exportOriginal(job.id) }.buttonStyle(AppButtonStyle(kind: .quiet))
        }
    }
    private var detailsButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: { Label(expanded ? "Свернуть" : "Подробности", systemImage: expanded ? "chevron.up" : "chevron.down") }
            .buttonStyle(AppButtonStyle(kind: .quiet))
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
            HStack {
                Text(job.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: Locale(identifier: "ru_RU"))))
                Spacer()
                SmallBadge(title: backupExists ? "Резерв" : "Нет резерва", symbol: "externaldrive")
            }
            detailLine("Источник", value: job.sourcePath)
            if let previous = job.previousPath { detailLine("Прежнее имя", value: previous) }
            detailLine("SHA-256", value: job.source.digest, monospaced: true)
            if let work = job.workspacePath {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: work)) } label: { Label("Открыть рабочий каталог", systemImage: "folder") }.buttonStyle(AppButtonStyle())
            }
            ForEach(job.outputs) { output in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(URL(fileURLWithPath: output.path).lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 8)
                        SmallBadge(title: output.state.title)
                    }
                    Text(output.settings.action.title).foregroundStyle(AppTheme.secondary)
                    Text(output.settings.options.compactSummary(for: output.format)).foregroundStyle(AppTheme.muted)
                    if [.awaiting, .prepared].contains(job.state), output.state != .cancelled {
                        Button("Отменить ветку") { model.coordinator.cancelOutput(job.id, outputID: output.id) }.buttonStyle(AppButtonStyle())
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).appSurface(padding: 16, color: AppTheme.elevated)
            }
        }.font(.system(size: 11)).textSelection(.enabled)
    }
    private func detailLine(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            Text(value).font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(AppTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
