import SwiftUI
import RenamorphCore

enum AppTheme {
    static let canvas = color(0x3b3b3b)
    static let surface = color(0x353535)
    static let elevated = color(0x414141)
    static let sidebar = color(0x404040)
    static let selection = color(0x606060)
    static let border = color(0x515151)
    static let separator = color(0x555555)
    static let muted = color(0xafafaf)
    static let secondary = color(0xd4d4d4)
    static let text = color(0xeeeeee)
    static let accent = color(0xb8b8b8)
    static let blue = color(0x0a84ff)
    static let teal = color(0x52b8c4)
    static let violet = color(0x8b80e8)
    static let coral = color(0xee896f)
    static let green = color(0x80c38a)
    static let cardRadius: CGFloat = 16

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

enum AppButtonKind { case primary, secondary, quiet }

struct AppButtonStyle: ButtonStyle {
    var kind: AppButtonKind = .secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(AppTheme.text)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(kind == .secondary ? AppTheme.separator : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
    private var background: Color {
        if kind == .primary { return hovering && isEnabled ? AppTheme.selection : AppTheme.separator }
        if hovering && isEnabled { return AppTheme.selection }
        return kind == .secondary ? AppTheme.elevated : .clear
    }
}

struct SurfaceModifier: ViewModifier {
    var padding: CGFloat
    var color: Color
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(color, in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
    }
}

extension View {
    func appSurface(padding: CGFloat = 18, color: Color = AppTheme.surface) -> some View {
        modifier(SurfaceModifier(padding: padding, color: color))
    }
}

struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(AppTheme.muted)
    }
}

struct IconTile: View {
    let symbol: String
    var color: Color = AppTheme.accent
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: size * 0.25))
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

struct SmallBadge: View {
    let title: String
    var color: Color = AppTheme.muted
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
            Text(title)
        }.font(.system(size: 11, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.07), in: Capsule()).fixedSize()
    }
}

struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).accessibilityHidden(true)
            Text(title).font(.system(size: 15, weight: .medium))
            actions
        }.foregroundStyle(AppTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

struct AppSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.muted).accessibilityHidden(true)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(AppTheme.muted).accessibilityLabel("Очистить поиск")
            }
        }.padding(8).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct OptionMenu<Value: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Value
    @ViewBuilder var options: Options
    var body: some View {
        Menu {
            Picker(title, selection: $selection) { options }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 12) {
                Text(value).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(AppTheme.muted)
            }.foregroundStyle(AppTheme.secondary).padding(.horizontal, 12).padding(.vertical, 10)
                .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.separator))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(AppTheme.text)
            .accessibilityLabel(title).accessibilityValue(value)
    }
}

extension FileFormat.Family {
    var symbol: String {
        switch self {
        case .raster: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .subtitles: return "captions.bubble"
        }
    }
    var tint: Color {
        switch self {
        case .raster: return AppTheme.violet
        case .audio: return AppTheme.teal
        case .video: return AppTheme.coral
        case .subtitles: return AppTheme.blue
        }
    }
}

extension JobState {
    var requiresAttention: Bool { [.awaiting, .prepared, .needsRecovery, .restoreConflict].contains(self) }
    var appearsInQueue: Bool { isInFlight || requiresAttention }
    var tint: Color {
        switch self {
        case .failed, .needsRecovery, .restoreConflict, .unsupported: return .orange
        case .succeeded, .restored: return AppTheme.green
        case .awaiting, .prepared: return AppTheme.secondary
        case .cancelled: return AppTheme.muted
        default: return AppTheme.violet
        }
    }
    var symbol: String {
        switch self {
        case .succeeded, .restored: return "checkmark.circle"
        case .failed, .needsRecovery, .restoreConflict, .unsupported: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .awaiting, .prepared: return "clock"
        default: return "arrow.triangle.2.circlepath"
        }
    }
}

extension AlphaPolicy {
    var shortTitle: String { self == .reject ? "Отклонять" : "Белый фон" }
}

extension GroupPolicy {
    var shortTitle: String { self == .undecided ? "Не выбрано" : "Подготовить все результаты" }
}

extension MediaMode {
    var shortTitle: String {
        switch self {
        case .preferRemux: return "Автоматически"
        case .transcode: return "Перекодировать"
        case .remuxOnly: return "Перепаковать"
        }
    }
}

extension M4ACodec {
    var shortTitle: String { self == .aac ? "AAC" : "ALAC" }
}

extension ConversionOptions {
    func compactSummary(for format: FileFormat) -> String {
        if format.isMedia {
            return "\(mediaMode.shortTitle) · \(audioBitrate) кбит/с · \(audioSampleRate == 0 ? "Исходная частота" : "\(audioSampleRate) Гц")" + (format.family == .video ? " · CRF \(videoCRF)" : "")
        }
        if format.family == .subtitles { return "UTF-8" }
        return "\(Int(jpegQuality * 100))% · \(alpha.shortTitle)"
    }
}
