import AppKit
import SwiftUI

struct PCPage: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "ПК", subtitle: "Monitor Switcher для Windows працює в парі з цим Mac")

            if let pc = model.config.pc {
                PairedCard(pc: pc)
            } else {
                SetupCard(manualHost: $manualHost)
            }

            Card {
                SectionTitle(title: "Навіщо програма на ПК", symbol: "questionmark.circle")
                VStack(alignment: .leading, spacing: 8) {
                    Bullet(symbol: "hand.tap", text: "ПК повідомляє Mac, коли ви справді почали ним користуватися. Клавіатура, що просто заснула, більше не перемикає монітори.")
                    Bullet(symbol: "cable.connector", text: "ПК перемикає входи моніторів по своєму кабелю, якщо перехідник Mac не пропускає DDC.")
                    Bullet(symbol: "menubar.rectangle", text: "У треї Windows є кнопки «Монітори → Mac / ПК» для ручного перемикання.")
                }
            }

            DownloadCard()
        }
        .onAppear { model.refreshPC() }
    }
}

private struct PairedCard: View {
    @Environment(AppModel.self) private var model
    let pc: PairedPC

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "pc")
                    .font(.system(size: 26))
                    .frame(width: 52, height: 52)
                    .background(Palette.gradient(.pc), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pc.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        StatusDot(isOn: model.pcOnline == true)
                        Text(statusText).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { model.refreshPC() } label: { Label("Перевірити", systemImage: "arrow.clockwise") }
                Button("Від'єднати", role: .destructive) { model.unpairPC() }
            }

            if let error = model.pcError, model.pcOnline == false {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            if !model.pcMonitors.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Монітори, які бачить ПК").font(.headline)
                ForEach(model.pcMonitors) { monitor in
                    HStack(spacing: 10) {
                        Image(systemName: "display").foregroundStyle(Palette.tint(.pc)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(monitor.name).font(.body.weight(.medium))
                            Text(monitor.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if monitor.ddc {
                            Pill(text: "DDC ✓ · \(InputSource.name(UInt16(max(0, monitor.input))))", symbol: "cable.connector", color: .blue)
                        } else {
                            Pill(text: "DDC недоступний", color: .orange)
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        let version = model.pcVersion.map { " · версія \($0)" } ?? ""
        switch model.pcOnline {
        case true?: return "на зв'язку · \(pc.host)\(version)"
        case false?: return "не відповідає · \(pc.host)"
        case nil: return "перевіряю… · \(pc.host)"
        }
    }
}

private struct SetupCard: View {
    @Environment(AppModel.self) private var model
    @Binding var manualHost: String

    var body: some View {
        Card {
            SectionTitle(title: "Підключити ПК", symbol: "link")
            Text("Запустіть Monitor Switcher на ПК (як завантажити — нижче), потім натисніть «Знайти ПК». На ПК з'явиться запит — натисніть «Дозволити».")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    model.discoverPCs()
                } label: {
                    if model.isDiscovering {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Шукаю…") }
                    } else {
                        Label("Знайти ПК", systemImage: "magnifyingglass")
                    }
                }
                .controlSize(.large)
                .disabled(model.isDiscovering || model.pairingHost != nil)
                Spacer()
            }

            ForEach(model.discoveredPCs) { pc in
                HStack(spacing: 12) {
                    Image(systemName: "pc").font(.title3).foregroundStyle(Palette.tint(.pc))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pc.name).font(.body.weight(.medium))
                        Text("\(pc.host) · версія \(pc.version)\(pc.paired ? " · вже підключений до іншого Mac" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Підключити") { model.pair(host: pc.host, port: pc.port) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pairingHost != nil)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let host = model.pairingHost {
                BannerView(text: "Чекаю підтвердження на ПК (\(host))… Натисніть «Дозволити» на екрані ПК.",
                           color: Palette.tint(.pc), showsProgress: true)
            }
            if let error = model.pairingError {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Text("Або за IP-адресою:").foregroundStyle(.secondary)
                TextField("192.168.1.20", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { model.pair(host: manualHost) }
                Button("Підключити") { model.pair(host: manualHost) }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || model.pairingHost != nil)
            }
            Text("IP-адресу ПК видно у вікні Monitor Switcher на ПК, у розділі «Налаштування».")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DownloadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            SectionTitle(title: "Програма для Windows", symbol: "arrow.down.circle")
            if model.windowsAppURL == nil {
                Text("Ця збірка Mac-застосунку не містить файлу для Windows.").foregroundStyle(.secondary)
            } else if let error = model.serverError {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            } else {
                Text("Відкрийте на ПК у браузері одну з адрес — Mac сам віддасть MonitorSwitcher.exe. Після запуску програма встановиться, додасться в автозапуск і житиме в треї.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.downloadLinks, id: \.self) { link in
                    LinkLine(text: link)
                }
                HStack {
                    Button {
                        if let url = model.windowsAppURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: { Label("Показати .exe у Finder", systemImage: "folder") }
                    Text("— якщо зручніше перенести файл іншим способом.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Якщо macOS спитає про доступ до локальної мережі — дозвольте, інакше ПК не зможе зв'язатися з Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LinkLine: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
