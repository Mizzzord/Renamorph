import SwiftUI
import RenamorphCore

struct OverviewView: View {
    @ObservedObject var model: AppModel
    let navigate: (AppSection) -> Void
    private var awaiting: Int { model.state.jobs.filter { $0.state == .awaiting }.count }
    private var running: Int { model.state.jobs.filter { $0.state.isInFlight || $0.state == .prepared }.count }
    private var succeeded: Int { model.state.jobs.filter { $0.state == .succeeded }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            SectionHeading(title: "Все операции")
            HStack(spacing: 20) {
                metric("Ожидают", value: awaiting)
                metric("В работе", value: running)
                metric("Готово", value: succeeded)
                metric("Папки", value: model.state.settings.folders.count)
            }.appSurface(padding: 22)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "Действия")
                action("Добавить папку", symbol: "folder.badge.plus") { model.chooseFolder() }
                action("Открыть задания", symbol: "square.stack.3d.up") { navigate(.queue) }
                action("Настройки", symbol: "slider.horizontal.3") { navigate(.settings) }
                action("Форматы", symbol: "arrow.triangle.branch") { navigate(.formats) }
            }
            if !model.state.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        SectionHeading(title: "Последние операции")
                        Spacer()
                        Button("Все") { navigate(.history) }.buttonStyle(.plain)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(model.state.jobs.suffix(3).reversed())) { job in
                            Button { navigate(job.state.appearsInQueue ? .queue : .history) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: job.image?.format.family.symbol ?? "doc").foregroundStyle(AppTheme.muted).frame(width: 20)
                                    Text(job.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(job.state.title).foregroundStyle(AppTheme.muted).font(.system(size: 12))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.appSurface(padding: 16)
                }
            }
        }
    }
    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(value)").font(.system(size: 21, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 13)).foregroundStyle(AppTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 18) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(AppTheme.muted).frame(width: 24)
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(AppTheme.muted)
            }.padding(.vertical, 10).padding(.horizontal, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
