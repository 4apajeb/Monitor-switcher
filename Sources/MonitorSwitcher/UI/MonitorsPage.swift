import SwiftUI

struct MonitorsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeader(title: "Monitors", subtitle: "How each monitor moves to the PC and back")
                Spacer()
                Button {
                    model.refreshDisplays()
                    model.refreshPC()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            if model.config.monitors.isEmpty {
                Card { Text("No external monitors found").foregroundStyle(.secondary) }
            }

            ForEach($model.config.monitors) { $rule in
                MonitorCard(rule: $rule)
            }

            Card {
                SectionTitle(title: "Finding the right input codes", symbol: "questionmark.circle")
                Text("Monitors switch inputs with a DDC/CI code. Standard codes are listed in the menus, but some brands use their own (Samsung often uses 5 and 6). To find them: while a monitor shows the Mac, press “Use for Mac”; switch it to the PC with its own buttons, press Refresh, then “Use for PC”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        if rule.isPortrait { Pill(text: "portrait", symbol: "rectangle.portrait") }
                    }
                }
                Spacer()
                if rule.method != .ignore {
                    Button {
                        model.testMonitor(rule)
                    } label: {
                        if isTesting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                        } else {
                            Label("Test", systemImage: "play.circle")
                        }
                    }
                    .disabled(model.testingMonitor != nil || model.isSwitching || model.mode == .pc)
                    .help("Hand this monitor to the PC for 5 seconds, then bring it back")
                }
            }

            Picker("Method", selection: $rule.method) {
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
                    InputPicker(title: "Mac input", symbol: Mode.mac.symbol, value: $rule.macInput, tint: Palette.tint(.mac))
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    InputPicker(title: "PC input", symbol: Mode.pc.symbol, value: $rule.pcInput, tint: Palette.tint(.pc))
                }
                if let current = model.currentInput(of: rule) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye").foregroundStyle(.secondary)
                        Text("Showing now: \(InputSource.name(current.value)) (code \(current.value), read via \(current.source))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use for Mac") { rule.macInput = current.value }
                            .controlSize(.small)
                            .disabled(rule.macInput == current.value)
                        Button("Use for PC") { rule.pcInput = current.value }
                            .controlSize(.small)
                            .disabled(rule.pcInput == current.value)
                    }
                }
            }

            if rule.method == .ddc, let state, state.ddc == .noReply || state.ddc == .unavailable {
                if let pcMonitor = model.pcMonitor(for: rule), pcMonitor.ddc {
                    HStack {
                        BannerView(text: "The Mac's connection doesn't pass DDC to this monitor, but the PC can control it.",
                                   symbol: "lightbulb.fill", color: .blue)
                        Button("Use DDC via PC") { rule.method = .pcHelper }
                    }
                } else {
                    BannerView(text: "The Mac gets no DDC reply from this monitor — its adapter probably doesn't pass DDC. Pair the PC app to switch it from the PC, or try “Cut Mac signal”.",
                               symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }

            if rule.method == .pcHelper {
                if model.config.pc == nil {
                    BannerView(text: "Pair the PC app first (PC page).", symbol: "exclamationmark.triangle.fill", color: .orange)
                } else if let pcMonitor = model.pcMonitor(for: rule) {
                    Text(pcMonitor.ddc
                         ? "The PC controls this monitor as \(pcMonitor.id)."
                         : "The PC sees this monitor, but it doesn't answer DDC from the PC either.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.pcOnline == true {
                    BannerView(text: "The PC doesn't see a monitor named \(rule.name).", symbol: "exclamationmark.triangle.fill", color: .orange)
                }
            }

            if state == nil, !model.isCut(rule) {
                HStack {
                    Text("Not connected to the Mac right now").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget", role: .destructive) { model.forget(rule) }
                }
            }
        }
    }

    @ViewBuilder private var connectionPill: some View {
        if state != nil {
            Pill(text: "connected", symbol: "checkmark", color: .green)
        } else if model.isCut(rule) {
            Pill(text: "Mac signal off", symbol: "bolt.slash", color: Palette.tint(.pc))
        } else {
            Pill(text: "not connected", symbol: "xmark", color: .secondary)
        }
    }

    @ViewBuilder private var ddcPill: some View {
        switch state?.ddc {
        case let .works(input)?:
            Pill(text: "DDC ✓ · \(InputSource.name(input))", symbol: "cable.connector", color: .blue)
        case .noReply?, .unavailable?:
            Pill(text: "no DDC from Mac", symbol: "cable.connector.slash", color: .orange)
        case .checking?:
            Pill(text: "checking DDC…", color: .secondary)
        case nil:
            EmptyView()
        }
    }
}

/// A preset menu plus a free-form code field, so any vendor-specific code can be used.
private struct InputPicker: View {
    let title: String
    let symbol: String
    @Binding var value: UInt16
    let tint: Color

    private var options: [(value: UInt16, name: String)] {
        var list = InputSource.presets
        if !list.contains(where: { $0.value == value }) { list.append((value, "Code \(value)")) }
        return list
    }

    private var code: Binding<Int> {
        Binding(get: { Int(value) }, set: { value = UInt16(clamping: max(0, $0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            HStack(spacing: 6) {
                Picker(title, selection: $value) {
                    ForEach(options, id: \.value) { option in
                        Text(option.name).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                TextField("Code", value: code, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                    .help("DDC/CI input code (VCP 0x60)")
            }
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
