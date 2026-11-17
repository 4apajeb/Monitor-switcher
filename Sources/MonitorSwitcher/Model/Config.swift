import CoreGraphics
import Foundation

enum Mode: String, Codable {
    case mac, pc

    var title: String { self == .mac ? "Mac" : "ПК" }
    var symbol: String { self == .mac ? "macmini" : "pc" }
}

enum SwitchMethod: String, Codable, CaseIterable, Identifiable {
    case ddc, pcHelper, cutSignal, ignore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ddc: return "DDC з Mac"
        case .pcHelper: return "DDC через ПК"
        case .cutSignal: return "Вимкнути сигнал"
        case .ignore: return "Не чіпати"
        }
    }

    var symbol: String {
        switch self {
        case .ddc: return "cable.connector"
        case .pcHelper: return "pc"
        case .cutSignal: return "bolt.horizontal.circle"
        case .ignore: return "minus.circle"
        }
    }

    var explanation: String {
        switch self {
        case .ddc:
            return "Mac напряму каже монітору, який вхід увімкнути. Працює в обидва боки, навіть коли монітор показує ПК."
        case .pcHelper:
            return "Mac просить Monitor Switcher на ПК перемкнути вхід цього монітора по DDC через кабель ПК. Підходить, коли перехідник Mac не пропускає DDC."
        case .cutSignal:
            return "Mac вимикає свій сигнал на цей монітор, і той сам переходить на активний вхід ПК. Коли сигнал Mac повертається, монітор перемикається назад. Потрібна функція Auto Source Switch у меню монітора."
        case .ignore:
            return "Монітор не перемикається автоматично."
        }
    }

    var usesInputs: Bool { self == .ddc || self == .pcHelper }
}

enum InputSource {
    static let presets: [(value: UInt16, name: String)] = [
        (15, "DisplayPort 1"), (16, "DisplayPort 2"),
        (17, "HDMI 1"), (18, "HDMI 2"), (27, "USB-C"),
        // Samsung uses its own codes, and they differ per model (G50A: 5 = HDMI, 6 = DP;
        // LF24T450F: 5 = HDMI 1, 6 = HDMI 2).
        (5, "Samsung · код 5"), (6, "Samsung · код 6"),
        (3, "DVI 1"), (1, "VGA 1"),
    ]

    static func name(_ value: UInt16) -> String {
        presets.first { $0.value == value }?.name ?? "Код \(value)"
    }
}

struct MonitorRule: Codable, Identifiable, Equatable {
    var uuid: String
    var name: String
    var method: SwitchMethod
    var macInput: UInt16
    var pcInput: UInt16
    /// Last CGDirectDisplayID seen for this monitor — needed to turn its signal back on.
    var displayID: UInt32?
    /// Last known position in the macOS display arrangement (for the overview map).
    var frame: CGRect?
    /// EDID PnP id (e.g. AUS25BA) as the Mac sees it.
    var pnpID: String?
    /// The id the PC app uses for this monitor. Samsungs report a different product code on
    /// each input (SAM7095 on the Mac's HDMI, SAM7094 on the PC's), so it is matched by name too.
    var pcID: String?

    var id: String { uuid }
    var isPortrait: Bool { (frame?.height ?? 0) > (frame?.width ?? 1) }

    init(uuid: String, name: String, method: SwitchMethod, macInput: UInt16, pcInput: UInt16,
         displayID: UInt32? = nil, frame: CGRect? = nil) {
        self.uuid = uuid
        self.name = name
        self.method = method
        self.macInput = macInput
        self.pcInput = pcInput
        self.displayID = displayID
        self.frame = frame
    }
}

struct TriggerDevice: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var id: String { key }
}

enum TriggerRule: String, Codable, CaseIterable, Identifiable {
    case all, any
    var id: String { rawValue }
    var title: String { self == .all ? "Усі вибрані відключились" : "Будь-який відключився" }
}

/// A display whose signal the app turned off — remembered on disk so it can always be restored.
struct CutDisplay: Codable, Equatable {
    var uuid: String
    var displayID: UInt32
    var name: String
}

struct AppConfig: Codable, Equatable {
    var monitors: [MonitorRule] = []
    var triggers: [TriggerDevice] = []
    var triggerRule: TriggerRule = .all
    var automationEnabled = true
    /// Only switch to the PC if the Mac was used within `activityWindow` seconds before the
    /// devices disconnected. Keyboards that fall asleep after inactivity won't trigger a switch.
    var activityGuard = true
    var activityWindow: Double = 30
    var disconnectDelay: Double = 1.5
    var showWindowAtLaunch = false
    var launchAtLoginWanted = true
    var hasCompletedSetup = false
    var cutDisplays: [CutDisplay] = []
    var pc: PairedPC?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        monitors = try c.decodeIfPresent([MonitorRule].self, forKey: .monitors) ?? d.monitors
        triggers = try c.decodeIfPresent([TriggerDevice].self, forKey: .triggers) ?? d.triggers
        triggerRule = try c.decodeIfPresent(TriggerRule.self, forKey: .triggerRule) ?? d.triggerRule
        automationEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? d.automationEnabled
        activityGuard = try c.decodeIfPresent(Bool.self, forKey: .activityGuard) ?? d.activityGuard
        activityWindow = try c.decodeIfPresent(Double.self, forKey: .activityWindow) ?? d.activityWindow
        disconnectDelay = try c.decodeIfPresent(Double.self, forKey: .disconnectDelay) ?? d.disconnectDelay
        showWindowAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .showWindowAtLaunch) ?? d.showWindowAtLaunch
        launchAtLoginWanted = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginWanted) ?? d.launchAtLoginWanted
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? d.hasCompletedSetup
        cutDisplays = try c.decodeIfPresent([CutDisplay].self, forKey: .cutDisplays) ?? d.cutDisplays
        pc = try c.decodeIfPresent(PairedPC.self, forKey: .pc)
    }
}

enum ConfigStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MonitorSwitcher", isDirectory: true)
    }()

    static let fileURL = directory.appendingPathComponent("config.json")

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    static func save(_ config: AppConfig) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MonitorSwitcher: failed to save config: \(error)")
        }
    }
}
