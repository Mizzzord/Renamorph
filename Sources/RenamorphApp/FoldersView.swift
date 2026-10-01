import SwiftUI
import AppKit
import RenamorphCore

struct FoldersView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.state.settings.folders.isEmpty {
                EmptyState(symbol: "folder", title: "Нет папок") {
                    Button("Добавить папку") { model.chooseFolder() }.buttonStyle(AppButtonStyle())
                }
            } else {
                SectionHeading(title: "Наблюдаемые папки")
                LazyVStack(spacing: 16) {
                    ForEach(model.state.settings.folders) { folder in folderRow(folder) }
                }.appSurface()
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    SectionHeading(title: "Исключения")
                    Spacer(minLength: 12)
                    Button { model.chooseFolder(exclusion: true) } label: { Label("Добавить", systemImage: "plus") }.buttonStyle(AppButtonStyle())
                }
                if exclusions.isEmpty {
                    Text("Нет исключений").font(.system(size: 13)).foregroundStyle(AppTheme.muted)
                }
                ForEach(exclusions, id: \.self) { path in
                    HStack(spacing: 12) {
                        Image(systemName: "folder.badge.minus").foregroundStyle(AppTheme.muted).frame(width: 24).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12, weight: .medium))
                            Text(path)
                                .font(.system(size: 10)).foregroundStyle(AppTheme.muted).textSelection(.enabled)
                                .lineLimit(2).truncationMode(.middle).help(path)
                        }
                        Spacer(minLength: 8)
                        Button { model.modify { $0.exclusions.removeAll { $0 == path } } } label: { Image(systemName: "xmark") }
                            .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Убрать исключение \(path)")
                    }
                }
            }.appSurface()
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(get: { model.state.settings.handleNewFiles }, set: { value in model.modify { $0.handleNewFiles = value } })) {
                    Text("Новые файлы с неверным расширением").font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.toggleStyle(.switch).accessibilityLabel("Новые файлы с неверным расширением")
            }.appSurface()
        }
    }
    private var exclusions: [String] { model.state.settings.exclusions.filter { $0 != model.coordinator.store.directory.path } }
    private func folderRow(_ folder: WatchFolder) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(AppTheme.muted).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(folder.path).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(folder.path)
            }
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(AppButtonStyle()).accessibilityLabel("Открыть папку \(folder.path)")
            Button { model.modify { $0.folders.removeAll { $0.id == folder.id } } } label: { Image(systemName: "minus") }
                .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Прекратить наблюдение за \(folder.path)")
        }
    }
}
