import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater
    @State private var showExceptions = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.53, green: 0.80, blue: 0.68) : Color(red: 0.17, green: 0.43, blue: 0.39)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.system(size: 32, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 58, height: 58).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ясно").font(.system(size: 29, weight: .semibold, design: .rounded))
                    Text("Ваши слова. Нужная раскладка.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.5").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(model.monitor.enabled ? accent : Color.orange).frame(width: 8, height: 8)
                    Text(model.status).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Toggle("Авто", isOn: $model.enabled).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel("Автоматическое исправление раскладки")
                }
                Text("Українська · Русский · English · Deutsch").font(.system(size: 12)).foregroundStyle(.secondary)
                if model.carambaRunning {
                    Text("Выйдите из Caramba через её меню, чтобы два переключателя не исправляли текст одновременно.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.accessibility { permissionRow("Универсальный доступ", action: model.openAccessibility) }
                if !model.inputMonitoring { permissionRow("Мониторинг ввода", action: model.openInputMonitoring) }
            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 16) {
                feature("text.cursor", title: "Во время набора", subtitle: "Исправляет уверенно распознанное слово и адрес сайта до пробела. Короткие и неоднозначные слова проверяет при завершении.")
                feature("arrow.uturn.backward", title: "Один короткий Shift", subtitle: "Преобразует слово, символ или выделение. После замены буквы — только новый фрагмент. После автозамены — отмена. В пустом поле — следующий язык.")
                feature("character.bubble", title: "Русский и украинский отдельно", subtitle: "Короткие слова учитывают соседний текст. При неоднозначности — ваш выбор языка; правильные слова сохраняются.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Исправлять опечатки", isOn: $model.correctSpelling).toggleStyle(.checkbox)
                Text("После пробела · только однозначные варианты · короткий Shift — отменить")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Запускать при входе", isOn: Binding(get: { model.loginEnabled }, set: { _ in model.toggleLogin() })).toggleStyle(.checkbox)
                Spacer()
                Button("Исключения…") { showExceptions = true }
            }
            if updater.available {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle("Обновлять автоматически", isOn: $updater.automatic).toggleStyle(.checkbox)
                        Spacer()
                        Button("Проверить сейчас") { updater.check() }.disabled(updater.busy)
                    }
                    Text(updater.message.isEmpty ? "Каждый день в 21:00 с GitHub · разрешения macOS сохраняются" : updater.message)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.detail.isEmpty {
                Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Label("На вашем Mac · без истории ввода", systemImage: "lock.shield")
                Spacer()
                Text("Исправлено: \(model.corrections)")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 480).background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showExceptions) { exceptions }
    }

    private func permissionRow(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "circle.dashed").foregroundStyle(.orange)
            Text(title).font(.callout)
            Spacer()
            Button("Открыть настройки", action: action).controlSize(.small)
        }
    }

    private func feature(_ symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var exceptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Исключения").font(.title2.bold())
            Text("Не менять эти слова").font(.headline)
            TextEditor(text: $model.ignoredWords).font(.body.monospaced()).frame(height: 80)
                .border(Color.secondary.opacity(0.2)).accessibilityLabel("Слова исключения")
            Text("По одному слову в строке. Сохраняются автоматически.").font(.caption).foregroundStyle(.secondary)
            Text("Не работать в приложениях").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.excludedApps.keys.sorted(), id: \.self) { id in
                        HStack {
                            Text(model.excludedApps[id] ?? id)
                            Spacer()
                            Button { model.excludedApps.removeValue(forKey: id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Удалить исключение \(model.excludedApps[id] ?? id)")
                        }
                    }
                }.padding(8)
            }.frame(height: 110)
            Text("Добавить приложение можно через значок Ясно в строке меню, пока оно открыто.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Готово") { showExceptions = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 430)
    }
}
