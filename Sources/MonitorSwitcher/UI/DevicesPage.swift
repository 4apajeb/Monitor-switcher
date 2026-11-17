import SwiftUI

struct DevicesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Пристрої", subtitle: "Що означає «я пішов працювати за ПК»")

            Card {
                SectionTitle(title: "Клавіатура й миша", symbol: "keyboard")
                Text("Коли вибрані пристрої відключаються від Mac (ви перемкнули їх на ПК), монітори переходять на ПК. Щойно будь-який із них знову підключається до Mac — монітори повертаються.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    let rows = model.deviceRows
                    if rows.isEmpty {
                        Text("Не бачу жодної Bluetooth- чи USB-клавіатури або миші")
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
                SectionTitle(title: "Коли віддавати монітори ПК", symbol: "arrow.right.circle")

                Picker("Умова", selection: $model.config.triggerRule) {
                    ForEach(TriggerRule.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider().padding(.vertical, 4)

                Toggle(isOn: $model.config.activityGuard) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Захист від засинання клавіатури").font(.body.weight(.medium))
                        Text("Bluetooth-клавіатура й миша відключаються, коли засинають. Монітори перейдуть на ПК, лише якщо Mac використовували не раніше ніж за \(Int(model.config.activityWindow)) с до відключення.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if model.config.activityGuard {
                    LabeledSlider(title: "Вікно активності", value: $model.config.activityWindow, range: 5...180, step: 5, unit: "с")
                }

                LabeledSlider(title: "Затримка перед перемиканням", value: $model.config.disconnectDelay, range: 0...10, step: 0.5, unit: "с")
            }

            Card {
                SectionTitle(title: "Назад на Mac", symbol: "arrow.uturn.left.circle")
                Text("Будь-який вибраний пристрій знову підключився до Mac — монітори одразу повертаються. Без затримок і перевірок.")
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
                    Text(row.isConnected ? "з Mac" + (row.transport.map { " · \($0)" } ?? "") : "не з Mac (на ПК або спить)")
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
            Text(title).frame(width: 220, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value)) \(unit)" : String(format: "%.1f \(unit)", value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
