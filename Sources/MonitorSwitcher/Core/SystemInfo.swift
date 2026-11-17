import Foundation
import IOKit

enum DeviceKind: String, Codable {
    case keyboard, mouse, other

    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

enum SystemInfo {
    /// Seconds since the last keyboard/mouse/trackpad input on this Mac.
    static func idleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return 0 }
        return value.doubleValue / 1_000_000_000
    }

    /// Asks the Bluetooth subsystem what kind each paired device is (keyboard / mouse).
    /// Runs `system_profiler`, so call it off the main thread.
    static func bluetoothDeviceKinds() -> [String: DeviceKind] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controller = (root["SPBluetoothDataType"] as? [[String: Any]])?.first
        else { return [:] }

        var kinds: [String: DeviceKind] = [:]
        for section in ["device_connected", "device_not_connected"] {
            for entry in controller[section] as? [[String: Any]] ?? [] {
                for (name, info) in entry {
                    let minor = ((info as? [String: Any])?["device_minorType"] as? String ?? "").lowercased()
                    if minor.contains("keyboard") {
                        kinds[name] = .keyboard
                    } else if minor.contains("mouse") || minor.contains("trackpad") {
                        kinds[name] = .mouse
                    }
                }
            }
        }
        return kinds
    }
}
