import AppKit
import ServiceManagement
import SwiftUI

struct LogPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeader(title: "Журнал", subtitle: "Що відбувалося і чому")
                Spacer()
                Button("Показати файл") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL])
                }
                Button("Очистити") { model.clearLog() }
            }
            Card(padding: 14) {
                if model.log.isEmpty {
                    Text("Журнал порожній").foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.log.reversed()) { entry in
                            LogRow(entry: entry)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }
}

struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    private let appPath = Bundle.main.bundlePath

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Налаштування", subtitle: "Запуск, відновлення та швидкі команди")

            Card {
                SectionTitle(title: "Запуск", symbol: "power")
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Запускати разом з Mac").font(.body.weight(.medium))
                        Text("Monitor Switcher стартує після входу в систему й одразу працює в рядку меню.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if model.loginItemStatus == .requiresApproval {
                    BannerView(text: "macOS просить підтвердити автозапуск у Параметрах системи → Загальні → Об’єкти входу.",
                               symbol: "exclamationmark.triangle.fill", color: .orange)
                    Button("Відкрити «Об’єкти входу»") { SMAppService.openSystemSettingsLoginItems() }
                }

                Divider()

                Toggle(isOn: $model.config.showWindowAtLaunch) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Показувати це вікно під час автозапуску").font(.body.weight(.medium))
                        Text("Після закриття вікна застосунок лишається працювати — іконка в рядку меню вгорі праворуч.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Card {
                SectionTitle(title: "Аварійне відновлення", symbol: "lifepreserver")
                Text("Якщо монітор лишився без сигналу Mac, ця кнопка ввімкне сигнал на всіх моніторах і поверне їх на Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.restoreEverything()
                } label: {
                    Label("Повернути всі монітори на Mac", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .controlSize(.large)
                Text("Те саме з Термінала:").font(.caption).foregroundStyle(.secondary)
                CodeLine(text: "\"\(appPath)/Contents/MacOS/MonitorSwitcher\" --restore")
            }

            Card {
                SectionTitle(title: "Швидкі команди", symbol: "command")
                Text("Для Shortcuts, Raycast, Alfred чи гарячих клавіш:")
                    .font(.callout).foregroundStyle(.secondary)
                CodeLine(text: "open -g monitorswitcher://pc")
                CodeLine(text: "open -g monitorswitcher://mac")
                CodeLine(text: "open -g monitorswitcher://toggle")
            }

            .onAppear { model.refreshLoginItem() }

            Card {
                SectionTitle(title: "Про застосунок", symbol: "info.circle")
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                Text("Monitor Switcher \(version)").font(.callout)
                HStack {
                    Button("Папка налаштувань") { NSWorkspace.shared.open(ConfigStore.directory) }
                    Button("Файл журналу") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL]) }
                }
            }
        }
    }
}

private struct CodeLine: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Скопіювати")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
