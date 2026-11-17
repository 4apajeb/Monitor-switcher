import AppKit
import SwiftUI

enum Palette {
    static let macColors = [Color(red: 0.16, green: 0.50, blue: 1.00), Color(red: 0.30, green: 0.78, blue: 1.00)]
    static let pcColors = [Color(red: 0.52, green: 0.30, blue: 1.00), Color(red: 0.96, green: 0.37, blue: 0.68)]
    static let brandColors = [Color(red: 0.22, green: 0.48, blue: 1.00), Color(red: 0.62, green: 0.34, blue: 1.00)]

    static func gradient(_ mode: Mode) -> LinearGradient {
        LinearGradient(colors: mode == .mac ? macColors : pcColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func tint(_ mode: Mode) -> Color { mode == .mac ? macColors[0] : pcColors[0] }

    static let brand = LinearGradient(colors: brandColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.07)
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.cardBorder))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

struct SectionTitle: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).font(.headline)
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Palette.brand)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "display.2")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Palette.brandColors[1].opacity(0.35), radius: size * 0.12, y: size * 0.06)
    }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct StatusDot: View {
    let isOn: Bool
    var body: some View {
        Circle()
            .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .shadow(color: isOn ? .green.opacity(0.6) : .clear, radius: 3)
    }
}

/// A small drawing of a monitor, landscape or portrait.
struct MonitorGlyph: View {
    var portrait: Bool
    var tint: Color = .accentColor

    var body: some View {
        let size = portrait ? CGSize(width: 22, height: 34) : CGSize(width: 38, height: 24)
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint, lineWidth: 2.5)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15)))
                .frame(width: size.width, height: size.height)
            RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 12, height: 3)
        }
        .frame(width: 44, height: 44)
    }
}

struct BannerView: View {
    let text: String
    var symbol: String = "hourglass"
    var color: Color = .orange
    var showsProgress = false

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension LogEntry.Level {
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .device: return "dot.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .device: return .blue
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.formatter.string(from: entry.date))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: entry.level.symbol)
                .foregroundStyle(entry.level.color)
                .frame(width: 16)
            Text(entry.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}
