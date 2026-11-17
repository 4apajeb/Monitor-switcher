import AppKit
import ServiceManagement
import SwiftUI

struct LogPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeader(title: "Activity", subtitle: "What happened and why")
                Spacer()
                Button("Show log file") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL])
                }
                Button("Clear") { model.clearLog() }
            }
            Card(padding: 14) {
                if model.log.isEmpty {
                    Text("Nothing here yet").foregroundStyle(.secondary)
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
            PageHeader(title: "Settings", subtitle: "Startup, updates and recovery")

            UpdatesCard()

            Card {
                SectionTitle(title: "Startup", symbol: "power")
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open at login").font(.body.weight(.medium))
                        Text("Monitor Switcher starts when you log in and runs in the menu bar.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if model.loginItemStatus == .requiresApproval {
                    BannerView(text: "macOS wants you to allow it in System Settings → General → Login Items.",
                               symbol: "exclamationmark.triangle.fill", color: .orange)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }

                Divider()

                Toggle(isOn: $model.config.showWindowAtLaunch) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Show this window at login").font(.body.weight(.medium))
                        Text("When the window is closed the app keeps running — look for the monitors icon in the menu bar.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .onAppear { model.refreshLoginItem() }

            Card {
                SectionTitle(title: "Emergency restore", symbol: "lifepreserver")
                Text("If a monitor is stuck on the PC or without the Mac's signal, this turns the Mac's output back on for every monitor and sends each one back to its Mac input.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.restoreEverything()
                } label: {
                    Label("Bring all monitors back", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .controlSize(.large)
                Text("The same from Terminal:").font(.caption).foregroundStyle(.secondary)
                CodeLine(text: "\"\(appPath)/Contents/MacOS/MonitorSwitcher\" --restore")
            }

            Card {
                SectionTitle(title: "Shortcuts", symbol: "command")
                Text("For Shortcuts, Raycast, Alfred or a keyboard shortcut:")
                    .font(.callout).foregroundStyle(.secondary)
                CodeLine(text: "open -g monitorswitcher://pc")
                CodeLine(text: "open -g monitorswitcher://mac")
                CodeLine(text: "open -g monitorswitcher://toggle")
            }

            Card {
                SectionTitle(title: "Files", symbol: "folder")
                HStack {
                    Button("Settings folder") { NSWorkspace.shared.open(ConfigStore.directory) }
                    Button("Log file") { NSWorkspace.shared.activateFileViewerSelecting([AppModel.logURL]) }
                }
            }
        }
    }
}

private struct UpdatesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card {
            SectionTitle(title: "Updates", symbol: "arrow.down.circle")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Version \(model.appVersion)").font(.body.weight(.medium))
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                switch model.updateState {
                case let .available(release):
                    Button("Update to \(release.version)") { model.installUpdate(release) }
                        .buttonStyle(.borderedProminent)
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check now") { model.checkForUpdates(userInitiated: true) }
                }
            }

            if case let .available(release) = model.updateState, !release.notes.isEmpty {
                Text(release.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            Toggle(isOn: $model.config.autoUpdate) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install updates automatically").font(.body.weight(.medium))
                    Text("New versions are downloaded from GitHub (\(Updater.repository)) and installed; the app restarts by itself in a second. The PC app updates itself the same way.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var statusText: String {
        switch model.updateState {
        case .idle: return "Checks for updates automatically"
        case .checking: return "Checking GitHub…"
        case .upToDate: return "You're up to date" + lastChecked
        case let .available(release): return "Version \(release.version) is available"
        case let .installing(release): return "Installing \(release.version)…"
        case let .failed(message): return message
        }
    }

    private var lastChecked: String {
        guard let date = model.lastUpdateCheck else { return "" }
        return " · checked " + date.formatted(date: .omitted, time: .shortened)
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
            .help("Copy")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
