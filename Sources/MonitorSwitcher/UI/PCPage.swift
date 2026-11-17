import AppKit
import SwiftUI

struct PCPage: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "PC", subtitle: "Monitor Switcher for Windows works as a pair with this Mac")

            if let pc = model.config.pc {
                PairedCard(pc: pc)
            } else {
                SetupCard(manualHost: $manualHost)
            }

            Card {
                SectionTitle(title: "Why install the PC app", symbol: "questionmark.circle")
                VStack(alignment: .leading, spacing: 8) {
                    Bullet(symbol: "hand.tap", text: "The PC tells the Mac when you actually start using it, so a keyboard that just fell asleep never switches the monitors.")
                    Bullet(symbol: "cable.connector", text: "The PC can switch inputs over its own cables when the Mac's adapters don't pass DDC.")
                    Bullet(symbol: "menubar.rectangle", text: "The Windows tray icon has “Monitors → Mac / PC” for manual switching.")
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
                Button { model.refreshPC() } label: { Label("Check", systemImage: "arrow.clockwise") }
                Button("Unpair", role: .destructive) { model.unpairPC() }
            }

            if let error = model.pcError, model.pcOnline == false {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            if !model.pcMonitors.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Monitors the PC sees").font(.headline)
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
                            Pill(text: "no DDC", color: .orange)
                        }
                    }
                }
            }
        }
    }

    private var statusText: String {
        let version = model.pcVersion.map { " · version \($0)" } ?? ""
        switch model.pcOnline {
        case true?: return "online · \(pc.host)\(version)"
        case false?: return "not answering · \(pc.host)"
        case nil: return "checking… · \(pc.host)"
        }
    }
}

private struct SetupCard: View {
    @Environment(AppModel.self) private var model
    @Binding var manualHost: String

    var body: some View {
        Card {
            SectionTitle(title: "Pair a PC", symbol: "link")
            Text("Start Monitor Switcher on the PC (see below how to get it), then press Find PCs. The PC will ask you to confirm — press Allow there.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    model.discoverPCs()
                } label: {
                    if model.isDiscovering {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching…") }
                    } else {
                        Label("Find PCs", systemImage: "magnifyingglass")
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
                        Text("\(pc.host) · version \(pc.version)\(pc.paired ? " · paired with another Mac" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair") { model.pair(host: pc.host, port: pc.port) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pairingHost != nil)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let host = model.pairingHost {
                BannerView(text: "Waiting for confirmation on the PC (\(host))… Press Allow on the PC's screen.",
                           color: Palette.tint(.pc), showsProgress: true)
            }
            if let error = model.pairingError {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            }

            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Text("Or by IP address:").foregroundStyle(.secondary)
                TextField("192.168.1.20", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { model.pair(host: manualHost) }
                Button("Pair") { model.pair(host: manualHost) }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || model.pairingHost != nil)
            }
            Text("The PC's address is shown in Monitor Switcher's window on the PC, under Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DownloadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            SectionTitle(title: "Get the Windows app", symbol: "arrow.down.circle")
            if let error = model.serverError {
                BannerView(text: error, symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            Text("Open one of these addresses in a browser on the PC — the Mac serves MonitorSwitcher.exe itself. Or download it from the GitHub releases page. On first run it installs itself, starts with Windows and lives in the tray.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.windowsAppURL != nil {
                ForEach(model.downloadLinks, id: \.self) { link in
                    LinkLine(text: link)
                }
            }
            LinkLine(text: "https://github.com/\(Updater.repository)/releases/latest")
            HStack {
                if let url = model.windowsAppURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Label("Show .exe in Finder", systemImage: "folder") }
                }
                Spacer()
            }
            Text("If macOS asks whether Monitor Switcher may find devices on your local network, allow it — otherwise the Mac and the PC can't talk.")
                .font(.caption).foregroundStyle(.secondary)
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
                .font(.system(.body, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
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
