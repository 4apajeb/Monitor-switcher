import CoreGraphics
import Foundation

enum CLI {
    static func restore() {
        var config = ConfigStore.load()
        let online = Set(DisplayOutput.onlineDisplayIDs())
        var ids = config.cutDisplays.map(\.displayID)
        for rule in config.monitors where rule.method == .cutSignal {
            if let id = rule.displayID, !online.contains(id), !ids.contains(id) { ids.append(id) }
        }
        let failures = DisplayOutput.set(ids, enabled: true)
        for id in ids {
            print(failures[id] == nil ? "display \(id): signal on" : "display \(id): failed (\(failures[id]!.rawValue))")
        }
        Thread.sleep(forTimeInterval: 1.5)
        let found = DisplayDiscovery.externalDisplays()
        for rule in config.monitors where rule.method == .ddc {
            guard let display = found.first(where: { $0.uuid == rule.uuid }) else { continue }
            do {
                try DDC.write(display, vcp: VCP.inputSource, value: rule.macInput, timing: .patient)
                print("\(rule.name): input \(rule.macInput)")
            } catch {
                print("\(rule.name): \(error)")
            }
        }
        config.cutDisplays.removeAll { failures[$0.displayID] == nil }
        ConfigStore.save(config)
    }

    static func probe() {
        print("Private DDC API:", PrivateAPI.isAvailable ? "ok" : "missing")
        print("Display on/off API:", DisplayOutput.isAvailable ? "ok" : "missing")
        print("Idle:", String(format: "%.1f s", SystemInfo.idleSeconds()))
        for display in DisplayDiscovery.externalDisplays() {
            var status = "no DDC transport"
            if display.hasDDCTransport {
                do {
                    let value = try DDC.read(display, vcp: VCP.inputSource)
                    status = "DDC ok, input \(value.current) (\(InputSource.name(value.current)))"
                } catch {
                    status = "DDC: \(error)"
                }
            }
            print("- \(display.name) [\(display.uuid)] id=\(display.displayID) \(CGDisplayBounds(display.displayID)) — \(status)")
        }
        let monitor = HIDMonitor()
        monitor.start()
        for device in monitor.devices.values.sorted(by: { $0.name < $1.name }) {
            print("• \(device.name) — \(device.transport) [\(device.key)]")
        }
    }
}
