import CoreGraphics
import Foundation
import IOKit

// MARK: - Private Apple Silicon DDC entry points (resolved at runtime)

/// Thin wrapper around the private IOAVService / CoreDisplay APIs that Apple Silicon
/// Macs use to talk DDC/CI to external displays. Symbols are resolved with `dlsym`
/// so the app does not need to link against private frameworks.
enum PrivateAPI {
    typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias InfoDictionary = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
    ]

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        for handle in handles {
            if let sym = dlsym(handle, name) {
                return unsafeBitCast(sym, to: type)
            }
        }
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { // RTLD_DEFAULT
            return unsafeBitCast(sym, to: type)
        }
        return nil
    }

    static let createWithService = symbol("IOAVServiceCreateWithService", as: CreateWithService.self)
    static let readI2C = symbol("IOAVServiceReadI2C", as: ReadI2C.self)
    static let writeI2C = symbol("IOAVServiceWriteI2C", as: WriteI2C.self)
    static let displayInfo = symbol("CoreDisplay_DisplayCreateInfoDictionary", as: InfoDictionary.self)

    static var isAvailable: Bool {
        createWithService != nil && readI2C != nil && writeI2C != nil && displayInfo != nil
    }
}

// MARK: - Display discovery

/// An external display that macOS currently knows about, with its DDC transport (if any).
struct ExternalDisplay: Identifiable, Hashable {
    let displayID: CGDirectDisplayID
    let uuid: String
    let name: String
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let alphanumericSerial: String?
    let ioLocation: String
    fileprivate let transport: DDCTransport?

    var id: String { uuid }
    var hasDDCTransport: Bool { transport != nil }

    /// EDID PnP id as Windows shows it, e.g. vendor 0x06B3 + product 0x25BA → "AUS25BA".
    var pnpID: String {
        let v = vendor & 0xFFFF
        let letters = [(v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F]
            .map { Character(UnicodeScalar(UInt8(64 + $0))) }
        return String(letters) + String(format: "%04X", model & 0xFFFF)
    }
    var isBuiltInHDMI: Bool { transport?.chipAddress == DDCTransport.mcdpChipAddress }

    static func == (lhs: ExternalDisplay, rhs: ExternalDisplay) -> Bool { lhs.uuid == rhs.uuid }
    func hash(into hasher: inout Hasher) { hasher.combine(uuid) }
}

struct DDCTransport {
    static let defaultChipAddress: UInt32 = 0x37
    /// The MCDP29xx DP→HDMI converter behind the built-in HDMI port routes DDC through 0xB7.
    static let mcdpChipAddress: UInt32 = 0xB7

    let service: CFTypeRef
    let chipAddress: UInt32
}

enum DisplayDiscovery {
    /// Enumerates online external displays and pairs each with its DCPAVServiceProxy.
    static func externalDisplays() -> [ExternalDisplay] {
        guard PrivateAPI.isAvailable, let infoFn = PrivateAPI.displayInfo else { return [] }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        var result: [ExternalDisplay] = []
        for displayID in ids.prefix(Int(count)) where CGDisplayIsBuiltin(displayID) == 0 {
            guard let info = infoFn(displayID)?.takeRetainedValue() as? [String: Any],
                  let uuid = info["kCGDisplayUUID"] as? String,
                  let location = info["IODisplayLocation"] as? String
            else { continue }

            let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
            guard framebuffer != MACH_PORT_NULL else { continue }
            defer { IOObjectRelease(framebuffer) }

            var name = "Display \(displayID)"
            var alnumSerial: String?
            if let attrs = searchProperty(framebuffer, "DisplayAttributes") as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any] {
                name = product["ProductName"] as? String ?? name
                alnumSerial = product["AlphanumericSerialNumber"] as? String
            }

            result.append(ExternalDisplay(
                displayID: displayID,
                uuid: uuid,
                name: name,
                vendor: CGDisplayVendorNumber(displayID),
                model: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID),
                alphanumericSerial: alnumSerial,
                ioLocation: location,
                transport: transport(forFramebuffer: framebuffer)
            ))
        }
        return result
    }

    private static func searchProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively))
    }

    /// Walks the IOService plane in order: the DCPAVServiceProxy that follows a framebuffer
    /// belongs to that framebuffer (same approach as m1ddc / MonitorControl).
    private static func transport(forFramebuffer framebuffer: io_registry_entry_t) -> DDCTransport? {
        guard let create = PrivateAPI.createWithService else { return nil }
        var targetID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(framebuffer, &targetID) == KERN_SUCCESS else { return nil }

        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var matches = false
        while case let entry = IOIteratorNext(iterator), entry != MACH_PORT_NULL {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var entryID: UInt64 = 0
                matches = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS && entryID == targetID
                continue
            }
            guard matches else { continue }

            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuf)
            guard String(cString: nameBuf) == "DCPAVServiceProxy" else { continue }
            guard (searchProperty(entry, "Location") as? String) == "External" else { continue }
            guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }

            var chip = DDCTransport.defaultChipAddress
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if provider == "AppleDCPMCDP29XX" { chip = DDCTransport.mcdpChipAddress }
                IOObjectRelease(parent)
            }
            return DDCTransport(service: service, chipAddress: chip)
        }
        return nil
    }
}

// MARK: - DDC/CI protocol

enum DDCError: Error, CustomStringConvertible {
    case noTransport
    case apiUnavailable
    case ioError(IOReturn)
    case badReply([UInt8])

    var description: String {
        switch self {
        case .noTransport: return "дисплей не має DDC-каналу"
        case .apiUnavailable: return "приватні DDC API недоступні"
        case let .ioError(code): return String(format: "помилка I2C 0x%08x", code)
        case let .badReply(bytes): return "некоректна відповідь: " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
}

struct DDCTiming {
    var writeCycles = 2
    var writeDelay: useconds_t = 10_000
    var readDelay: useconds_t = 50_000
    var retries = 3

    static let standard = DDCTiming()
    static let patient = DDCTiming(writeCycles: 3, writeDelay: 40_000, readDelay: 120_000, retries: 4)
}

enum VCP {
    static let brightness: UInt8 = 0x10
    static let inputSource: UInt8 = 0x60
    static let power: UInt8 = 0xD6
}

struct DDCValue {
    let current: UInt16
    let maximum: UInt16
}

enum DDC {
    private static let hostAddress: UInt8 = 0x51
    private static let displayAddress: UInt8 = 0x6E

    static func write(_ display: ExternalDisplay, vcp: UInt8, value: UInt16, timing: DDCTiming = .standard) throws {
        guard let transport = display.transport else { throw DDCError.noTransport }
        guard let writeFn = PrivateAPI.writeI2C else { throw DDCError.apiUnavailable }

        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(displayAddress ^ hostAddress, ^)

        var lastError: IOReturn = kIOReturnSuccess
        for _ in 0..<max(1, timing.writeCycles) {
            usleep(timing.writeDelay)
            lastError = packet.withUnsafeMutableBytes {
                writeFn(transport.service, transport.chipAddress, UInt32(hostAddress), $0.baseAddress!, UInt32($0.count))
            }
        }
        if lastError != kIOReturnSuccess { throw DDCError.ioError(lastError) }
    }

    static func read(_ display: ExternalDisplay, vcp: UInt8, timing: DDCTiming = .standard) throws -> DDCValue {
        guard let transport = display.transport else { throw DDCError.noTransport }
        guard let writeFn = PrivateAPI.writeI2C, let readFn = PrivateAPI.readI2C else { throw DDCError.apiUnavailable }

        var request: [UInt8] = [0x82, 0x01, vcp, 0]
        request[3] = request[0..<3].reduce(displayAddress ^ hostAddress, ^)

        var lastError: DDCError = .badReply([])
        for attempt in 0..<max(1, timing.retries) {
            if attempt > 0 { usleep(timing.readDelay) }
            usleep(timing.writeDelay)
            let wr = request.withUnsafeMutableBytes {
                writeFn(transport.service, transport.chipAddress, UInt32(hostAddress), $0.baseAddress!, UInt32($0.count))
            }
            guard wr == kIOReturnSuccess else { lastError = .ioError(wr); continue }

            usleep(timing.readDelay)
            var reply = [UInt8](repeating: 0, count: 12)
            let rd = reply.withUnsafeMutableBytes {
                readFn(transport.service, transport.chipAddress, UInt32(hostAddress), $0.baseAddress!, UInt32($0.count))
            }
            guard rd == kIOReturnSuccess else { lastError = .ioError(rd); continue }

            // Reply: 6E 88 02 <rc> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>
            let checksum = reply[0..<10].reduce(UInt8(0x50), ^)
            if reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp, reply[10] == checksum {
                return DDCValue(current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                                maximum: UInt16(reply[6]) << 8 | UInt16(reply[7]))
            }
            lastError = .badReply(reply)
        }
        throw lastError
    }
}
