import SwiftUI
import AppKit
import RenamorphCore

typealias ViewState<Value> = SwiftUI.State<Value>

enum Section: String, CaseIterable, Identifiable {
    case queue = "Задания", folders = "Папки", rules = "Настройки", history = "История", formats = "Форматы"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .queue: return "square.stack.3d.up"
        case .folders: return "folder"
        case .rules: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .formats: return "arrow.triangle.branch"
        }
    }
}
struct MainView: View {
    @ObservedObject var model: AppModel
    @ViewState private var section: Section? = .queue
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Renamorph").font(.system(size: 20, weight: .semibold))
                        Text("ФАЙЛЫ ОСТАЮТСЯ У ВАС").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 17).padding(.top, 23)
                List(Section.allCases, selection: $section) { item in
                    Label(item.rawValue, systemImage: item.icon).padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.state.settings.paused ? "На паузе" : "Локальная обработка", systemImage: model.state.settings.paused ? "pause.circle" : "lock.shield")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.teal)
                    Text("Оригинал сохраняется перед каждым преобразованием.").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((section ?? .queue).rawValue).font(.system(size: 29, weight: .semibold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if section == .folders {
                        Button { model.chooseFolder() } label: { Label("Добавить папку", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.teal)
                    } else {
                        Button(model.state.settings.paused ? "Продолжить" : "Приостановить") { model.modify { $0.paused.toggle() } }
                    }
                }.padding(28)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch section ?? .queue {
                        case .queue: queueContent
                        case .folders: folderContent
                        case .rules: SettingsView(model: model)
                        case .history: historyContent
                        case .formats: formatsContent
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.state.settings.paused ? Color.orange : Color.teal).frame(width: 6, height: 6)
                    Text(model.diagnostic).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.coordinator.watcher.rescan() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Сверить снимок без запуска конвертаций")
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.tint(.teal)
    }
    var subtitle: String {
        switch section ?? .queue {
        case .queue: return "Новое расширение — желаемый формат. Источник определяется по содержимому."
        case .folders: return "Обрабатываются только выбранные области, кроме исключений."
        case .rules: return "Общие параметры, правила пар и лимиты хранения."
        case .history: return "Результаты, резервные копии и восстановление исходных байтов."
        case .formats: return "Фактически реализованные маршруты этой сборки."
        }
    }
    var active: [Job] { model.state.jobs.reversed().filter { [.inspecting, .awaiting, .queued, .preparing, .running, .validating, .prepared, .publishing, .needsRecovery, .restoring, .restoreConflict].contains($0.state) } }
    var queueContent: some View {
        Group {
            HStack(spacing: 14) {
                metric("Ожидают решения", value: model.state.jobs.filter { $0.state == .awaiting }.count, icon: "hand.raised")
                metric("В работе", value: model.state.jobs.filter { $0.state.isInFlight || $0.state == .prepared }.count, icon: "arrow.triangle.2.circlepath")
                metric("Готово", value: model.state.jobs.filter { $0.state == .succeeded }.count, icon: "checkmark.circle")
            }
            if model.state.settings.folders.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 36)).foregroundStyle(.teal)
                    Text("Начните с одной папки").font(.title2.weight(.semibold))
                    Text("Добавьте папку, затем измените расширение файла: photo.heic → photo.jpg, song.flac → song.mp3 или clip.mov → clip.mp4. Renamorph предложит преобразование и сохранит оригинал.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Выбрать папку…") { model.chooseFolder() }.buttonStyle(.borderedProminent).tint(.teal)
                    Text("Уже существующие файлы не конвертируются при первом сканировании.").font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading).card()
            } else if active.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.shield").font(.system(size: 40)).foregroundStyle(.teal)
                    Text("Всё спокойно").font(.title2.weight(.medium))
                    Text("Ожидаем изменения расширения в выбранных папках.").foregroundStyle(.secondary)
                    Text("Неподдерживаемые запросы и завершённые операции доступны в истории.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 58).card()
            }
            ForEach(active) { JobCard(job: $0, model: model) }
            if let latest = model.state.jobs.last, active.isEmpty { Text("Последнее событие").font(.headline); JobCard(job: latest, model: model) }
        }
    }
    func metric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: icon).foregroundStyle(.teal) }
            Text("\(value)").font(.system(size: 30, weight: .medium, design: .rounded))
        }.padding(19).frame(maxWidth: .infinity, alignment: .leading).card()
    }
    var folderContent: some View {
        Group {
            Text("Наблюдаемые папки").font(.headline)
            if model.state.settings.folders.isEmpty { Text("Папки пока не выбраны.").foregroundStyle(.secondary) }
            ForEach(model.state.settings.folders) { folder in
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(URL(fileURLWithPath: folder.path).lastPathComponent).font(.headline)
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: folder.path)) }
                    Button { model.modify { $0.folders.removeAll { $0.id == folder.id } } } label: { Image(systemName: "minus.circle") }.help("Прекратить наблюдение")
                }.padding(18).card()
            }
            HStack { Text("Исключения").font(.headline); Spacer(); Button("Добавить исключение…") { model.chooseFolder(exclusion: true) } }.padding(.top, 16)
            ForEach(model.state.settings.exclusions, id: \.self) { path in
                HStack { Text(path).font(.caption).textSelection(.enabled); Spacer(); Button("Убрать") { model.modify { $0.exclusions.removeAll { $0 == path } } }.disabled(path == model.coordinator.store.directory.path) }.padding(14).card()
            }
            Toggle("Обрабатывать новые файлы с неверным расширением", isOn: Binding(get: { model.state.settings.handleNewFiles }, set: { value in model.modify { $0.handleNewFiles = value } })).padding(.top, 15)
            Text("По умолчанию обрабатывается только доказанная смена расширения. Сверка после запуска, потери событий или перемещения корня не запускает массовых преобразований.").font(.caption).foregroundStyle(.secondary)
            Text("Поддерживается внутренний локальный APFS. Скрытые файлы, пакеты, симлинки, hard links и облачные области пропускаются. Full Disk Access не требуется самим приложением; macOS может запросить доступ к выбранной папке.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var historyContent: some View {
        Group {
            HStack {
                Text("\(model.state.jobs.count) операций · записи сохраняются между запусками").foregroundStyle(.secondary)
                Spacer()
                Button("Открыть хранилище") { NSWorkspace.shared.open(model.coordinator.store.directory) }
            }
            if model.state.jobs.isEmpty { Text("История появится после первого запроса.").padding(.vertical, 40).foregroundStyle(.secondary) }
            ForEach(model.state.jobs.reversed()) { JobCard(job: $0, model: model) }
        }
    }
    var formatsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(model.coordinator.worker.available ? "Локальный движок доступен" : "RenamorphWorker отсутствует", systemImage: model.coordinator.worker.available ? "checkmark.circle.fill" : "exclamationmark.triangle").foregroundStyle(.teal)
            Text(MediaToolchain().description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(FileFormat.Family.allCases, id: \.self) { family in
                Text(family.rawValue).font(.title3.weight(.semibold)).padding(.top, 10)
                ForEach(FileFormat.allCases.filter { $0.family == family }) { source in
                    HStack(alignment: .top) {
                        Text(source.title).font(.headline).frame(width: 70, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(Route.all.filter { $0.source == source && $0.unavailableReason == nil }.map { $0.target.title }.joined(separator: " · "))
                            ForEach(Array(Set(Route.all.filter { $0.source == source }.compactMap { $0.unavailableReason })).sorted(), id: \.self) { reason in
                                Text("Недоступно: " + reason).font(.caption).foregroundStyle(.orange)
                            }
                            Text(source.isMedia ? "FFmpeg · кодеки и дорожки проверяются по содержимому" : source.family == .subtitles ? "UTF-8 · строгий разбор текста и тайм-кодов" : "ImageIO; WebP кодируется FFmpeg").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(15).card()
                }
            }
            Text("Аудио: до одной дорожки и 8 каналов, MP3 — mono/stereo. Видео: до одной видеодорожки и одной аудиодорожки. Для совместимых кодеков доступна перепаковка; иначе используется перекодирование с потерями. Обложки, дополнительные дорожки, HDR и вложенные субтитры отклоняются. Метаданные и главы не переносятся.").font(.callout).foregroundStyle(.secondary)
            Text("Изображения: один кадр, 8-bit sRGB, нормализация ориентации, удаление метаданных. WebP кодируется без потерь после нормализации; JPEG, HEIC и AVIF — с потерями. Анимации и многостраничные TIFF не поддерживаются. SRT ↔ VTT сохраняет текст и тайм-коды; оформление отклоняется.").font(.callout).foregroundStyle(.secondary)
            Text("Несколько результатов: song.mp3,flac или photo.png,webp. Все ветки читают один резерв оригинала. Публикация группы требует явно выбранной политики в настройках.").font(.callout)
            Text("PDF, Office, архивы, электронные книги, шрифты и 3D пока не реализованы. Совместимое расширение и исправление ошибочного имени оставляют байты без изменений.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct JobCard: View {
    let job: Job
    @ObservedObject var model: AppModel
    @ViewState private var expanded = false
    var color: Color {
        if [.failed, .needsRecovery, .restoreConflict, .unsupported].contains(job.state) { return .orange }
        if [.succeeded, .restored].contains(job.state) { return .teal }
        return .secondary
    }
    var backupExists: Bool { job.backupPath.map { SafeFiles.exists($0) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                Image(systemName: job.state == .succeeded ? "checkmark.circle.fill" : "doc.richtext").font(.title2).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.name).font(.headline).lineLimit(2)
                    Text("\(job.image?.format.title ?? "Неизвестный вход") → \(job.outputs.map { $0.format.title }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(job.state.title).font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 5).background(color.opacity(0.1), in: Capsule())
            }
            if job.state.isInFlight { ProgressView(value: job.progress).tint(.teal) }
            Text(job.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                if job.state == .awaiting {
                    Button("Преобразовать") { model.coordinator.approve(job.id) }.buttonStyle(.borderedProminent).tint(.teal)
                    Button("Отклонить") { model.coordinator.cancel(job.id) }
                } else if job.state == .prepared {
                    Button("Опубликовать группу") { model.coordinator.publishPrepared(job.id) }.disabled(model.state.settings.groupPolicy == .undecided)
                    Button("Отменить") { model.coordinator.cancel(job.id) }
                } else if [.inspecting, .queued, .preparing, .running, .validating].contains(job.state) {
                    Button("Отменить") { model.coordinator.cancel(job.id) }
                }
                if [.succeeded, .restoreConflict].contains(job.state) {
                    Button("Восстановить оригинал") { model.coordinator.undo(job.id) }.disabled(!backupExists)
                }
                if backupExists {
                    Button("Сохранить оригинал рядом") { model.coordinator.exportOriginal(job.id) }
                }
                Spacer()
                Button(expanded ? "Свернуть" : "Подробности") { expanded.toggle() }.buttonStyle(.plain).foregroundStyle(.teal)
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(job.createdAt.formatted(date: .abbreviated, time: .standard)) · \(job.trigger)")
                    Text("Источник: \(job.sourcePath)")
                    if let previous = job.previousPath { Text("Прежнее имя: \(previous)") }
                    Text("SHA-256: \(job.source.digest)").font(.system(size: 10, design: .monospaced))
                    Text(backupExists ? "Оригинал доступен в резерве" : "Резерв оригинала пока не создан или отсутствует").foregroundStyle(backupExists ? .teal : .secondary)
                    if let work = job.workspacePath { Button("Открыть рабочий каталог") { NSWorkspace.shared.open(URL(fileURLWithPath: work)) } }
                    ForEach(job.outputs) { output in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(URL(fileURLWithPath: output.path).lastPathComponent) · \(output.state.title)").fontWeight(.medium)
                                Spacer()
                                if [.awaiting, .prepared].contains(job.state), output.state != .cancelled {
                                    Button("Отменить ветку") { model.coordinator.cancelOutput(job.id, outputID: output.id) }
                                }
                            }
                            Text(output.settings.origin + ": " + output.settings.action.title)
                            Text(output.operation).fontWeight(.medium)
                            if let engine = output.engine { Text(engine) }
                            Text(output.settings.options.summary(for: output.format))
                            Text(output.losses).foregroundStyle(.secondary)
                        }.padding(10).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.font(.caption).textSelection(.enabled)
            }
        }.padding(20).card()
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ViewState private var source: FileFormat = .heic
    @ViewState private var target: FileFormat = .jpeg
    @ViewState private var action: RuleAction = .ask
    @ViewState private var quality: Double = 90
    @ViewState private var alpha: AlphaPolicy = .reject
    @ViewState private var mediaOptions = ConversionOptions()
    var targets: [FileFormat] { Route.all.filter { $0.source == source && $0.unavailableReason == nil }.map { $0.target } }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("По умолчанию").font(.headline)
                Picker("Перед преобразованием", selection: Binding(get: { model.state.settings.defaultAction }, set: { value in model.modify { $0.defaultAction = value } })) { ForEach(RuleAction.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 530)
                HStack {
                    Text("JPEG / HEIC / AVIF").frame(width: 160, alignment: .leading)
                    Slider(value: Binding(get: { model.state.settings.options.jpegQuality }, set: { value in model.modify { $0.options.jpegQuality = value } }), in: 0.1...1, step: 0.05)
                    Text("\(Int(model.state.settings.options.jpegQuality * 100))%").monospacedDigit().frame(width: 45)
                }.frame(maxWidth: 530)
                Picker("Прозрачность", selection: Binding(get: { model.state.settings.options.alpha }, set: { value in model.modify { $0.options.alpha = value } })) { ForEach(AlphaPolicy.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 530)
                MediaOptionsEditor(options: Binding(get: { model.state.settings.options }, set: { value in model.modify { $0.options = value } }))
                Picker("Несколько результатов", selection: Binding(get: { model.state.settings.groupPolicy }, set: { value in model.modify { $0.groupPolicy = value } })) { ForEach(GroupPolicy.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 630)
                Text("Вся группа готовится и проверяется до начала публикации. Затем файлы публикуются по одному с журналом восстановления. При прерывании возможна частично опубликованная группа; это отдельное состояние, требующее сверки.").font(.caption).foregroundStyle(.secondary)
            }.padding(22).card()
            VStack(alignment: .leading, spacing: 14) {
                Text("Правила для пар форматов").font(.headline)
                Text("Правило пары имеет приоритет над общими параметрами. Настройки фиксируются в задании при обнаружении. Конфликтующие правила блокируют преобразование.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.state.settings.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(rule.source.title) → \(rule.target.title) · \(rule.action.title)")
                            Text(rule.options.summary(for: rule.target)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Удалить") { model.modify { $0.rules.removeAll { $0.id == rule.id } } }
                    }.padding(.vertical, 7)
                }
                Divider()
                HStack {
                    Picker("Из", selection: $source) { ForEach(FileFormat.allCases) { Text($0.title).tag($0) } }
                    Picker("В", selection: $target) { ForEach(targets) { Text($0.title).tag($0) } }
                    Picker("Режим", selection: $action) { ForEach(RuleAction.allCases) { Text($0.title).tag($0) } }
                }
                .onChange(of: source) { _, _ in if !targets.contains(target), let first = targets.first { target = first } }
                HStack {
                    Text("Растр \(Int(quality))%").font(.caption).frame(width: 90)
                    Slider(value: $quality, in: 10...100, step: 5).frame(maxWidth: 160)
                    Picker("Альфа", selection: $alpha) { ForEach(AlphaPolicy.allCases) { Text($0.title).tag($0) } }
                }
                if source.isMedia { MediaOptionsEditor(options: $mediaOptions) }
                Button("Добавить правило") {
                    var options = mediaOptions; options.jpegQuality = quality / 100; options.alpha = alpha
                    model.modify { $0.rules.append(PairRule(source: source, target: target, action: action, options: options)) }
                }.disabled(!targets.contains(target) || model.state.settings.rules.contains { $0.source == source && $0.target == target })
            }.padding(22).card()
            VStack(alignment: .leading, spacing: 16) {
                Text("Резервы и ресурсы").font(.headline)
                Stepper(value: Binding(get: { Int(model.state.settings.backupLimitBytes / 1024 / 1024 / 1024) }, set: { value in model.modify { $0.backupLimitBytes = Int64(value) * 1024 * 1024 * 1024 } }), in: 1...1000) {
                    Text("Лимит резервов: \(model.state.settings.backupLimitBytes / 1024 / 1024 / 1024) ГБ")
                }
                Stepper(value: Binding(get: { Int(model.state.settings.maxInputBytes / 1024 / 1024) }, set: { value in model.modify { $0.maxInputBytes = Int64(value) * 1024 * 1024 } }), in: 128...8192, step: 128) {
                    Text("Максимальный вход: \(model.state.settings.maxInputBytes / 1024 / 1024) МБ")
                }
                Stepper(value: Binding(get: { Int(model.state.settings.workerTimeout) }, set: { value in model.modify { $0.workerTimeout = Double(value) } }), in: 60...3600, step: 60) {
                    Text("Тайм-аут движка: \(Int(model.state.settings.workerTimeout)) с")
                }
                Text("Старые оригиналы не удаляются автоматически. При достижении лимита новое преобразование останавливается до изменения файлов.").font(.caption).foregroundStyle(.secondary)
                Text("Один процесс конвертации одновременно. Вход до \(model.state.settings.maxInputBytes / 1024 / 1024) МБ, до \(model.state.settings.maxPixels / 1_000_000) Мп; тайм-аут \(Int(model.state.settings.workerTimeout)) с. Прогресс отражает этапы и результаты, а не процент работы кодека.").font(.caption).foregroundStyle(.secondary)
                Button("Показать резервное хранилище") { NSWorkspace.shared.open(model.coordinator.store.backups) }
            }.padding(22).card()
        }
    }
}

struct MediaOptionsEditor: View {
    @Binding var options: ConversionOptions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Аудио и видео").font(.subheadline.weight(.semibold))
            Picker("Обработка потоков", selection: $options.mediaMode) { ForEach(MediaMode.allCases) { Text($0.title).tag($0) } }
            Picker("Частота аудио", selection: $options.audioSampleRate) {
                Text("Как в источнике").tag(0); Text("44 100 Гц").tag(44100); Text("48 000 Гц").tag(48000)
            }
            Picker("M4A при перекодировании", selection: $options.m4aCodec) { ForEach(M4ACodec.allCases) { Text($0.title).tag($0) } }
            Stepper("Аудиобитрейт: \(options.audioBitrate) кбит/с", value: $options.audioBitrate, in: 32...320, step: 16)
            Stepper("Качество видео CRF: \(options.videoCRF)", value: $options.videoCRF, in: 16...35)
            Text("Битрейт и CRF применяются при перекодировании. Меньше CRF — выше качество и размер. AVI использует MPEG-4 q=3. WAV/AIFF/FLAC/CAF/WavPack — до 24 бит; Opus — 48 кГц. Перепаковка сохраняет сжатые потоки, но удаляет метаданные и главы.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 630)
    }
}

private extension View {
    func card() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.065), lineWidth: 1))
    }
}
