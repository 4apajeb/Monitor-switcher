import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Огляд", subtitle: "Кому зараз належать монітори")

            HStack(spacing: 16) {
                ModeCard(mode: .mac)
                ModeCard(mode: .pc)
            }

            if model.isSwitching {
                BannerView(text: "Перемикаю монітори…", color: Palette.tint(model.mode), showsProgress: true)
            } else if let note = model.pendingNote {
                BannerView(text: note, symbol: "hourglass", color: .orange)
            }

            Card {
                Toggle(isOn: $model.config.automationEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Автоматичне перемикання").font(.headline)
                        Text(automationSubtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if !model.triggerRows.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(model.triggerRows) { row in
                            HStack(spacing: 6) {
                                Image(systemName: row.kind.symbol)
                                Text(row.name).lineLimit(1)
                                StatusDot(isOn: row.isConnected)
                            }
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        Spacer()
                        Button("Змінити") { page = .devices }
                            .buttonStyle(.link)
                    }
                }
            }

            Card {
                HStack {
                    SectionTitle(title: "Монітори", symbol: "display.2")
                    Spacer()
                    Button("Налаштувати") { page = .monitors }.buttonStyle(.link)
                }
                ArrangementMap()
                    .frame(height: 210)
            }

            Card {
                HStack {
                    SectionTitle(title: "Останні події", symbol: "clock")
                    Spacer()
                    Button("Увесь журнал") { page = .log }.buttonStyle(.link)
                }
                let recent = Array(model.log.suffix(6).reversed())
                if recent.isEmpty {
                    Text("Поки що нічого не відбувалося").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(recent) { LogRow(entry: $0) }
                    }
                }
            }
        }
    }

    private var automationSubtitle: String {
        let names = model.config.triggers.map(\.name)
        if names.isEmpty { return "Оберіть клавіатуру й мишу на сторінці «Пристрої»" }
        let joined = names.count > 1
            ? names.dropLast().joined(separator: " або ") + " або " + names.last!
            : names[0]
        if model.config.pc != nil {
            return "Клавіатура чи миша пішли з Mac і ви почали працювати на ПК — монітори йдуть на ПК. \(joined) підключилась до Mac — монітори одразу назад."
        }
        return "Клавіатура й миша перейшли на ПК — монітори теж. \(joined) підключилась до Mac — монітори одразу назад."
    }
}

private struct ModeCard: View {
    @Environment(AppModel.self) private var model
    let mode: Mode
    @State private var hovering = false

    private var isActive: Bool { model.mode == mode }

    var body: some View {
        Button {
            if !isActive { model.switchTo(mode, reason: "вручну") }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 34, weight: .regular))
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer(minLength: 18)
                Text(mode.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(isActive ? "Монітори зараз тут" : "Натисніть, щоб віддати монітори")
                    .font(.callout)
                    .opacity(0.85)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(Palette.gradient(mode)) : AnyShapeStyle(Palette.cardBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isActive ? Color.clear : (hovering ? Palette.tint(mode).opacity(0.6) : Palette.cardBorder), lineWidth: 1.5)
            }
            .shadow(color: isActive ? Palette.tint(mode).opacity(0.35) : .clear, radius: 16, y: 8)
            .scaleEffect(hovering && !isActive ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(model.isSwitching)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.mode)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The monitors drawn the way they are arranged in macOS, colored by who owns them right now.
struct ArrangementMap: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let rules = model.config.monitors.filter { $0.frame != nil }
            if rules.isEmpty {
                Text("Шукаю монітори…").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let bounds = rules.reduce(CGRect.null) { $0.union($1.frame!) }
                let gap: CGFloat = 10
                let scale = min((geo.size.width - gap * 2) / bounds.width, (geo.size.height - gap * 2) / bounds.height)
                let offsetX = (geo.size.width - bounds.width * scale) / 2
                let offsetY = (geo.size.height - bounds.height * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(rules) { rule in
                        let f = rule.frame!
                        MonitorTile(rule: rule)
                            .frame(width: max(f.width * scale - gap, 40), height: max(f.height * scale - gap, 30))
                            .offset(x: offsetX + (f.minX - bounds.minX) * scale + gap / 2,
                                    y: offsetY + (f.minY - bounds.minY) * scale + gap / 2)
                    }
                }
            }
        }
    }
}

private struct MonitorTile: View {
    @Environment(AppModel.self) private var model
    let rule: MonitorRule

    private var owner: Mode? {
        rule.method == .ignore ? nil : model.mode
    }

    private var detail: String {
        switch rule.method {
        case .ddc, .pcHelper: return InputSource.name(model.mode == .mac ? rule.macInput : rule.pcInput)
        case .cutSignal: return model.mode == .mac ? "сигнал Mac" : "сигнал Mac вимкнено"
        case .ignore: return "не перемикається"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(owner.map { AnyShapeStyle(Palette.gradient($0)) } ?? AnyShapeStyle(Color.secondary.opacity(0.25)))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: rule.method.symbol)
                        Text(owner?.title ?? "—")
                    }
                    .font(.caption.weight(.bold))
                    Text(rule.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption2).opacity(0.9).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(8)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .animation(.easeInOut(duration: 0.3), value: model.mode)
    }
}
