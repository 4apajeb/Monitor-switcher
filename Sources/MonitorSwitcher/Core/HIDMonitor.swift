import Foundation
import IOKit
import IOKit.hid

/// A physical input device (keyboard, mouse…) as seen by macOS.
struct HIDDevice: Identifiable, Hashable {
    let key: String
    let name: String
    let vendorID: Int
    let productID: Int
    let transport: String

    var id: String { key }
    var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("bluetooth") }

    static func makeKey(vendorID: Int, productID: Int, name: String) -> String {
        "\(vendorID):\(productID):\(name)"
    }
}

enum HIDChange {
    case connected(HIDDevice)
    case disconnected(HIDDevice)
}

/// Watches HID devices appearing and disappearing using IOKit service notifications.
/// This needs no Input Monitoring permission because devices are never opened.
final class HIDMonitor {
    var onChange: ((HIDChange) -> Void)?
    private(set) var devices: [String: HIDDevice] = [:]

    private var entryKeys: [UInt64: String] = [:]
    private var refCounts: [String: Int] = [:]
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    private static let transports: Set<String> = ["Bluetooth", "Bluetooth Low Energy", "USB"]

    func start() {
        guard port == nil else { return }
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching(kIOHIDDeviceKey), { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<HIDMonitor>.fromOpaque(refcon).takeUnretainedValue().handleAdded(iterator, notify: true)
        }, refcon, &addedIterator)
        handleAdded(addedIterator, notify: false)

        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching(kIOHIDDeviceKey), { refcon, iterator in
            guard let refcon else { return }
            Unmanaged<HIDMonitor>.fromOpaque(refcon).takeUnretainedValue().handleRemoved(iterator)
        }, refcon, &removedIterator)
        handleRemoved(removedIterator)
    }

    private func handleAdded(_ iterator: io_iterator_t, notify: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let device = Self.describe(service) else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            entryKeys[entryID] = device.key
            let count = refCounts[device.key, default: 0] + 1
            refCounts[device.key] = count
            if count == 1 {
                devices[device.key] = device
                if notify { onChange?(.connected(device)) }
            }
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            guard let key = entryKeys.removeValue(forKey: entryID) else { continue }
            let count = refCounts[key, default: 1] - 1
            if count <= 0 {
                refCounts.removeValue(forKey: key)
                if let device = devices.removeValue(forKey: key) {
                    onChange?(.disconnected(device))
                }
            } else {
                refCounts[key] = count
            }
        }
    }

    private static func describe(_ service: io_service_t) -> HIDDevice? {
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let transport = prop(kIOHIDTransportKey) as? String, transports.contains(transport),
              let name = prop(kIOHIDProductKey) as? String, !name.isEmpty
        else { return nil }
        let vendor = (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
        let product = (prop(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
        return HIDDevice(key: HIDDevice.makeKey(vendorID: vendor, productID: product, name: name),
                         name: name, vendorID: vendor, productID: product, transport: transport)
    }
}
