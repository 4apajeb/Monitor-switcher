import SwiftUI

struct MonitorsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeader(title: "Монітори", subtitle: "Як кожен монітор переходить на ПК і повертається")
                Spacer()
                Button {
                    model.refreshDisplays()
                } label: {
                    Label("Оновити", systemImage: "arrow.clockwise")
                }
            }

            if model.config.monitors.isEmpty {
                Card { Text("Зовнішніх моніторів не знайдено").foregroundStyle(.secondary) }
            }

            ForEach($model.config.monitors) { $rule in
                MonitorCard(rule: $rule)
            }
        }
    }
}

private struct MonitorCard: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: MonitorRule

    private var state: DisplayState? { model.display(for: rule) }
    private var isTesting: Bool { model.testingMonitor == rule.uuid }

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                MonitorGlyph(portrait: rule.isPortrait, tint: rule.method == .ignore ? .secondary : Palette.tint(model.mode))
                VStack(alignment: .leading, spacing: 5) {
                    Text(rule.name).font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        connectionPill
                        ddcPill
                        if rule.isPortrait { Pill(text: "вертикальний", symbol: "rectangle.portrait") }
                    }
                }
                Spacer()
                if rule.method != .ignore {
                    Button {
                        model.testMonitor(rule)
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Перевіряю…") }
                        } else {
                            Label("Перевірити", systemImage: "play.circle")
                        }
                    }
                    .disabled(model.testingMonitor != nil || model.isSwitching || model.mode == .pc)
                    .help("Віддати цей монітор ПК на 5 секунд і повернути назад")
                }
            }

            Picker("Спосіб", selection: $rule.method) {
                ForEach(SwitchMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(rule.method.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rule.method.usesInputs {
                HStack(spacing: 14) {
                    InputPicker(title: "Вхід для Mac", symbol: Mode.mac.symbol, value: $rule.macInput, tint: Palette.tint(.mac))
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    InputPicker(title: "Вхід для ПК", symbol: Mode.pc.symbol, value: $rule.pcInput, tint: Palette.tint(.pc))
                }
            }

            if rule.method == .ddc, let state, state.ddc == .noReply || state.ddc == .unavailable {
                if let pcMonitor = model.pcMonitor(for: rule), pcMonitor.ddc {
                    HStack {
                        BannerView(text: "Перехідник Mac не пропускає DDC, але ПК керує цим монітором — оберіть «DDC через ПК».",
                                   symbol: "lightbulb.fill", color: .blue)
                        Button("Через ПК") { rule.method = .pcHelper }
                    }
                } else {
                    BannerView(text: "Mac не отримує відповіді від цього монітора по DDC — найімовірніше, перехідник не пропускає DDC. Підключіть ПК або спробуйте «Вимкнути сигнал».",
                               symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }

            if rule.method == .pcHelper {
                if model.config.pc == nil {
                    BannerView(text: "Спершу підключіть ПК на сторінці «ПК».", symbol: "exclamationmark.triangle.fill", color: .orange)
                } else if let pcMonitor = model.pcMonitor(for: rule) {
                    Text(pcMonitor.ddc
                         ? "ПК бачить цей монітор (\(pcMonitor.id)), зараз \(InputSource.name(UInt16(max(0, pcMonitor.input))))."
                         : "ПК бачить цей монітор, але DDC з ПК не відповідає.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.pcOnline == true {
                    BannerView(text: "ПК не бачить монітор \(rule.name) (\(rule.pnpID ?? "?")).", symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }

            if state == nil, !model.isCut(rule) {
                HStack {
                    Text("Монітор зараз не підключений до Mac").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Забути", role: .destructive) { model.forget(rule) }
                }
            }
        }
    }

    @ViewBuilder private var connectionPill: some View {
        if state != nil {
            Pill(text: "підключений", symbol: "checkmark", color: .green)
        } else if model.isCut(rule) {
            Pill(text: "сигнал Mac вимкнено", symbol: "bolt.slash", color: Palette.tint(.pc))
        } else {
            Pill(text: "не підключений", symbol: "xmark", color: .secondary)
        }
    }

    @ViewBuilder private var ddcPill: some View {
        switch state?.ddc {
        case let .works(input)?:
            Pill(text: "DDC ✓ · зараз \(InputSource.name(input))", symbol: "cable.connector", color: .blue)
        case .noReply?, .unavailable?:
            Pill(text: "DDC недоступний", symbol: "cable.connector.slash", color: .orange)
        case .checking?:
            Pill(text: "перевіряю DDC…", color: .secondary)
        case nil:
            EmptyView()
        }
    }
}

private struct InputPicker: View {
    let title: String
    let symbol: String
    @Binding var value: UInt16
    let tint: Color

    private var options: [(value: UInt16, name: String)] {
        var list = InputSource.presets
        if !list.contains(where: { $0.value == value }) { list.append((value, "Код \(value)")) }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Picker(title, selection: $value) {
                ForEach(options, id: \.value) { option in
                    Text(option.name).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
