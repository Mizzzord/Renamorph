import SwiftUI
import RenamorphCore

enum FormatFilter: String, CaseIterable, Identifiable {
    case all = "Все", images = "Изображения", audio = "Аудио", video = "Видео", subtitles = "Субтитры"
    var id: String { rawValue }
    var family: FileFormat.Family? {
        switch self {
        case .all: return nil
        case .images: return .raster
        case .audio: return .audio
        case .video: return .video
        case .subtitles: return .subtitles
        }
    }
}

struct FormatsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var query = ""
    @ViewState private var filter: FormatFilter = .all
    private var sources: [FileFormat] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileFormat.allCases.filter {
            (filter.family == nil || $0.family == filter.family) && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionHeading(title: "Форматы")
                Spacer()
                AppSearchField(placeholder: "Поиск", text: $query).frame(width: 200)
            }
            Picker("Тип формата", selection: $filter) {
                ForEach(FormatFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if !model.coordinator.worker.available {
                Label("Движок недоступен", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if sources.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Ничего не найдено") {
                    Button("Сбросить") { query = ""; filter = .all }.buttonStyle(AppButtonStyle())
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sources) { source in
                        FormatRow(source: source)
                        if source != sources.last { Divider().overlay(AppTheme.border) }
                    }
                }.appSurface()
            }
        }
    }
}

struct FormatRow: View {
    let source: FileFormat
    private var routes: [Route] { Route.all.filter { $0.source == source } }
    private var available: [Route] { routes.filter { $0.unavailableReason == nil } }
    private var reasons: [String] { Array(Set(routes.compactMap(\.unavailableReason))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: source.family.symbol).font(.system(size: 16)).foregroundStyle(AppTheme.muted).frame(width: 24).accessibilityHidden(true)
                Text(source.title).font(.system(size: 13, weight: .medium)).frame(width: 60, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(AppTheme.muted).padding(.top, 3).accessibilityHidden(true)
                Text(available.isEmpty ? "Недоступно" : available.map { $0.target.title }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(available.isEmpty ? Color.orange : AppTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !reasons.isEmpty {
                DisclosureGroup("Недоступно") {
                    ForEach(reasons, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 6) }
                }.font(.system(size: 11)).padding(.leading, 38)
            }
        }.padding(.vertical, 14)
    }
}
