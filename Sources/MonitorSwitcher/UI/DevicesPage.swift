import SwiftUI

struct DevicesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Devices", subtitle: "What tells the app you moved to the PC")

            Card {
                SectionTitle(title: "Keyboard and mouse", symbol: "keyboard")
                Text("Pick the devices you switch between the Mac and the PC (multi-host Bluetooth keyboards and mice). When they disconnect from the Mac, the monitors can go to the PC; as soon as any of them reconnects, the monitors come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    let rows = model.deviceRows
                    if rows.isEmpty {
                        Text("No Bluetooth or USB keyboards or mice found")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(rows) { row in
                        DeviceRowView(row: row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }

            Card {
                SectionTitle(title: "Going to the PC", symbol: "arrow.right.circle")

                if model.config.pc != nil {
                    Text("The PC app is paired, so the monitors move only when a selected device has left the Mac and you actually start using the PC. A keyboard that just fell asleep never switches anything.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The settings below are only used while the PC app can't be reached.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Without the PC app the Mac has to guess. Install Monitor Switcher on the PC (PC page) for reliable switching.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Condition", selection: $model.config.triggerRule) {
                    ForEach(TriggerRule.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider().padding(.vertical, 4)

                Toggle(isOn: $model.config.activityGuard) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ignore devices that fall asleep").font(.body.weight(.medium))
                        Text("Bluetooth keyboards and mice disconnect when they sleep. Only switch if the Mac was used within \(Int(model.config.activityWindow)) s before they disconnected.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if model.config.activityGuard {
                    LabeledSlider(title: "Activity window", value: $model.config.activityWindow, range: 5...180, step: 5, unit: "s")
                }

                LabeledSlider(title: "Delay before switching", value: $model.config.disconnectDelay, range: 0...10, step: 0.5, unit: "s")
            }

            Card {
                SectionTitle(title: "Coming back to the Mac", symbol: "arrow.uturn.left.circle")
                Text("As soon as any selected device reconnects to the Mac, the monitors come back — no delay, no checks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceRowView: View {
    @Environment(AppModel.self) private var model
    let row: DeviceRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.kind.symbol)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(row.isTrigger ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(row.isTrigger ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    StatusDot(isOn: row.isConnected)
                    Text(row.isConnected ? "on the Mac" + (row.transport.map { " · \($0)" } ?? "") : "not on the Mac (on the PC or asleep)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { row.isTrigger }, set: { model.setTrigger(row, enabled: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 200, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) \(unit)" : String(format: "%.1f \(unit)", value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
