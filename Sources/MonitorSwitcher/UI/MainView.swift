import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, monitors, devices, pc, log, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .monitors: return "Monitors"
        case .devices: return "Devices"
        case .pc: return "PC"
        case .log: return "Activity"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .monitors: return "display.2"
        case .devices: return "keyboard"
        case .pc: return "pc"
        case .log: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page = .overview

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $page)
                .frame(width: 224)
                .background(VisualEffect(material: .sidebar))

            Divider()

            ScrollView {
                Group {
                    switch page {
                    case .overview: OverviewPage(page: $page)
                    case .monitors: MonitorsPage()
                    case .devices: DevicesPage()
                    case .pc: PCPage()
                    case .log: LogPage()
                    case .settings: SettingsPage()
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .id(page) // start every page at the top
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(minWidth: 800, minHeight: 560)
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 52)

            HStack(spacing: 12) {
                AppGlyph(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Monitor Switcher").font(.headline)
                    Text("Monitors on the \(model.mode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 22)

            ForEach(Page.allCases) { item in
                SidebarItem(page: item, isSelected: page == item) {
                    withAnimation(.easeOut(duration: 0.15)) { page = item }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(model.config.automationEnabled ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(model.config.automationEnabled ? "Automatic switching on" : "Automatic switching paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 12)
    }
}

private struct SidebarItem: View {
    let page: Page
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(page.title)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
