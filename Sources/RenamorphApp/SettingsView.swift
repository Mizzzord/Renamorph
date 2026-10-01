import SwiftUI
import AppKit
import RenamorphCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case conversion = "Преобразование", rules = "Правила форматов", storage = "Резервы и ресурсы"
    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var tab: SettingsTab = .conversion
    @ViewState private var addingRule = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Раздел настроек", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .conversion: conversion
            case .rules: rules
            case .storage: storage
            }
        }
        .sheet(isPresented: $addingRule) { RuleEditor(model: model) }
    }

    private var options: Binding<ConversionOptions> {
        Binding(get: { model.state.settings.options }, set: { value in model.modify { $0.options = value } })
    }

    private var conversion: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "Режим")
                Picker("Действие по умолчанию", selection: Binding(get: { model.state.settings.defaultAction }, set: { value in model.modify { $0.defaultAction = value } })) {
                    ForEach(RuleAction.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }.appSurface()
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "Изображения")
                ImageOptionsEditor(options: options)
            }.appSurface()
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "Аудио и видео")
                MediaOptionsEditor(options: options)
            }.appSurface()
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(title: "Группы")
                OptionMenu(title: "Политика публикации группы", value: model.state.settings.groupPolicy.shortTitle, selection: Binding(get: { model.state.settings.groupPolicy }, set: { value in model.modify { $0.groupPolicy = value } })) {
                    ForEach(GroupPolicy.allCases) { Text($0.shortTitle).tag($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.appSurface()
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                SectionHeading(title: "Правила")
                Spacer(minLength: 8)
                Button { addingRule = true } label: { Label("Добавить правило", systemImage: "plus") }.buttonStyle(AppButtonStyle(kind: .primary))
            }
            if model.state.settings.rules.isEmpty {
                EmptyState(symbol: "arrow.triangle.branch", title: "Нет правил") { }
            }
            ForEach(model.state.settings.rules) { rule in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: rule.source.family.symbol).foregroundStyle(AppTheme.muted).frame(width: 24)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(rule.source.title).font(.system(size: 15, weight: .medium, design: .monospaced))
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(AppTheme.muted)
                            Text(rule.target.title).font(.system(size: 15, weight: .medium, design: .monospaced))
                            SmallBadge(title: rule.action.title, color: AppTheme.teal)
                        }
                        Text(rule.options.compactSummary(for: rule.target)).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { model.modify { $0.rules.removeAll { $0.id == rule.id } } } label: { Image(systemName: "trash") }
                        .buttonStyle(AppButtonStyle(kind: .quiet)).accessibilityLabel("Удалить правило \(rule.source.title) → \(rule.target.title)")
                }.appSurface(padding: 20)
            }
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "Резервные копии")
                SettingRow(title: "Лимит") {
                    Stepper(value: Binding(get: { Int(model.state.settings.backupLimitBytes / 1024 / 1024 / 1024) }, set: { value in model.modify { $0.backupLimitBytes = Int64(value) * 1024 * 1024 * 1024 } }), in: 1...1000) {
                        Text("\(model.state.settings.backupLimitBytes / 1024 / 1024 / 1024) ГБ").monospacedDigit()
                    }
                }
                Button { NSWorkspace.shared.open(model.coordinator.store.backups) } label: { Label("Открыть хранилище", systemImage: "externaldrive") }.buttonStyle(AppButtonStyle())
            }.appSurface()
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(title: "Обработка")
                SettingRow(title: "Размер файла") {
                    Stepper(value: Binding(get: { Int(model.state.settings.maxInputBytes / 1024 / 1024) }, set: { value in model.modify { $0.maxInputBytes = Int64(value) * 1024 * 1024 } }), in: 128...8192, step: 128) {
                        Text("\(model.state.settings.maxInputBytes / 1024 / 1024) МБ").monospacedDigit()
                    }
                }
                SettingRow(title: "Тайм-аут") {
                    Stepper(value: Binding(get: { Int(model.state.settings.workerTimeout) }, set: { value in model.modify { $0.workerTimeout = Double(value) } }), in: 60...3600, step: 60) {
                        Text("\(Int(model.state.settings.workerTimeout)) с").monospacedDigit()
                    }
                }
            }.appSurface()
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title).font(.system(size: 13)).frame(width: 150, alignment: .leading)
            control.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ImageOptionsEditor: View {
    @Binding var options: ConversionOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(title: "Качество") {
                HStack(spacing: 12) {
                    Slider(value: $options.jpegQuality, in: 0.1...1, step: 0.05).accessibilityLabel("Качество изображения")
                    Text("\(Int(options.jpegQuality * 100))%").font(.system(size: 12, design: .monospaced)).frame(width: 42)
                }
            }
            SettingRow(title: "Прозрачность") {
                OptionMenu(title: "Политика прозрачности", value: options.alpha.shortTitle, selection: $options.alpha) {
                    ForEach(AlphaPolicy.allCases) { Text($0.shortTitle).tag($0) }
                }
            }
        }
    }
}

struct MediaOptionsEditor: View {
    @Binding var options: ConversionOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(title: "Режим") {
                OptionMenu(title: "Режим обработки потоков", value: options.mediaMode.shortTitle, selection: $options.mediaMode) {
                    ForEach(MediaMode.allCases) { Text($0.shortTitle).tag($0) }
                }
            }
            SettingRow(title: "Частота аудио") {
                OptionMenu(title: "Частота аудио", value: options.audioSampleRate == 0 ? "Как в источнике" : "\(options.audioSampleRate) Гц", selection: $options.audioSampleRate) {
                    Text("Как в источнике").tag(0); Text("44 100 Гц").tag(44100); Text("48 000 Гц").tag(48000)
                }
            }
            SettingRow(title: "Кодек M4A") {
                OptionMenu(title: "Кодек M4A", value: options.m4aCodec.shortTitle, selection: $options.m4aCodec) {
                    ForEach(M4ACodec.allCases) { Text($0.shortTitle).tag($0) }
                }
            }
            SettingRow(title: "Аудиобитрейт") { Stepper("\(options.audioBitrate) кбит/с", value: $options.audioBitrate, in: 32...320, step: 16) }
            SettingRow(title: "Качество видео") { Stepper("CRF \(options.videoCRF)", value: $options.videoCRF, in: 16...35) }
        }
    }
}

struct RuleEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var source: FileFormat = .heic
    @ViewState private var target: FileFormat? = .jpeg
    @ViewState private var action: RuleAction = .ask
    @ViewState private var options = ConversionOptions()
    private var targets: [FileFormat] { Route.all.filter { $0.source == source && $0.unavailableReason == nil }.map(\.target) }
    private var duplicate: Bool { model.state.settings.rules.contains { $0.source == source && $0.target == target } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Новое правило").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(AppButtonStyle(kind: .quiet))
                    .accessibilityLabel("Закрыть редактор правила").keyboardShortcut(.cancelAction)
            }.padding(24)
            Rectangle().fill(AppTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 16) {
                        formatPicker("Исходный формат", selection: $source)
                        Image(systemName: "arrow.right").foregroundStyle(AppTheme.muted)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Новый формат").font(.system(size: 11)).foregroundStyle(AppTheme.muted)
                            OptionMenu(title: "Новый формат", value: target?.title ?? "Нет доступных целей", selection: $target) {
                                if targets.isEmpty { Text("Нет доступных целей").tag(Optional<FileFormat>.none) }
                                ForEach(targets) { Text($0.title).tag(Optional($0)) }
                            }.disabled(targets.isEmpty)
                        }.frame(maxWidth: .infinity)
                    }
                    Picker("Поведение правила", selection: $action) { ForEach(RuleAction.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    if source.family == .raster { ImageOptionsEditor(options: $options) }
                    if source.isMedia { MediaOptionsEditor(options: $options) }
                    if duplicate {
                        Label("Правило уже существует", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.system(size: 12))
                    } else if targets.isEmpty {
                        Label("Нет доступных форматов", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 12))
                    }
                }.padding(24)
            }
            HStack {
                Button("Отмена") { dismiss() }.buttonStyle(AppButtonStyle())
                Spacer()
                Button("Добавить правило") {
                    guard let target, targets.contains(target), !duplicate else { return }
                    model.modify { $0.rules.append(PairRule(source: source, target: target, action: action, options: options)) }
                    dismiss()
                }.buttonStyle(AppButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(target == nil || duplicate || !targets.contains(where: { $0 == target }))
            }.padding(24).background(AppTheme.elevated)
        }.frame(width: 620, height: source.isMedia ? 520 : (source.family == .subtitles ? 270 : 360))
            .background(AppTheme.surface).foregroundStyle(AppTheme.text).tint(AppTheme.accent).preferredColorScheme(.dark)
            .onChange(of: source) { _, _ in reconcileTarget() }.onAppear { reconcileTarget() }
    }
    private func reconcileTarget() { if !targets.contains(where: { $0 == target }) { target = targets.first } }
    private func formatPicker(_ title: String, selection: Binding<FileFormat>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(AppTheme.muted)
            OptionMenu(title: title, value: selection.wrappedValue.title, selection: selection) { ForEach(FileFormat.allCases) { Text($0.title).tag($0) } }
        }.frame(maxWidth: .infinity)
    }
}
