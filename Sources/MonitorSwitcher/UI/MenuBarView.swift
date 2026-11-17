import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    let openWindow: () -> Void
    let quit: () -> Void

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppGlyph(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Monitor Switcher").font(.headline)
                    Text(model.isSwitching ? "Перемикаю…" : "Монітори у \(model.mode == .mac ? "Mac" : "ПК")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSwitching { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 8) {
                ModeButton(mode: .mac)
                ModeButton(mode: .pc)
            }

            Toggle(isOn: $model.config.automationEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Автоматично")
                    Text("за клавіатурою й мишею").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if !model.triggerRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.triggerRows) { row in
                        HStack(spacing: 8) {
                            Image(systemName: row.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                            Text(row.name).lineLimit(1)
                            Spacer()
                            StatusDot(isOn: row.isConnected)
                            Text(row.isConnected ? "Mac" : "—").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .leading)
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let note = model.pendingNote {
                Label(note, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
            }

            Divider()

            VStack(spacing: 2) {
                MenuRow(title: "Відкрити Monitor Switcher", symbol: "macwindow", action: openWindow)
                MenuRow(title: "Вийти", symbol: "power", action: quit)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct ModeButton: View {
    @Environment(AppModel.self) private var model
    let mode: Mode

    private var isActive: Bool { model.mode == mode }

    var body: some View {
        Button {
            if !isActive { model.switchTo(mode, reason: "вручну з рядка меню") }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol).font(.system(size: 22))
                Text(mode.title).font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Palette.gradient(mode)) : AnyShapeStyle(Color.primary.opacity(0.06)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.isSwitching)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.mode)
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
