import CoreGraphics
import Foundation

/// Turns the Mac's video output to individual displays on and off.
///
/// A display whose output is turned off disappears from macOS (its windows move to the
/// remaining screens) and the monitor sees "no signal". Monitors with an automatic source
/// switch (most Samsungs) then jump to whatever input is active — the PC. When the output is
/// turned back on, they see a new signal and jump back to the Mac.
///
/// The change does NOT revert on its own if the app quits, so callers must remember which
/// displays they turned off (see `AppConfig.cutDisplays`).
enum DisplayOutput {
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    private static let configureEnabled: ConfigureEnabled? = {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(sym, to: ConfigureEnabled.self)
    }()

    static var isAvailable: Bool { configureEnabled != nil }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Applies the change to all displays in one transaction (one desktop reconfiguration).
    /// If that fails, retries each display on its own so one missing monitor does not block
    /// the others. Returns the IDs that failed.
    @discardableResult
    static func set(_ ids: [CGDirectDisplayID], enabled: Bool) -> [CGDirectDisplayID: CGError] {
        guard let configure = configureEnabled else {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, CGError.notImplemented) })
        }
        guard !ids.isEmpty else { return [:] }
        if ids.count > 1, apply(ids, enabled: enabled, configure: configure) == .success {
            return [:]
        }
        var failures: [CGDirectDisplayID: CGError] = [:]
        for id in ids {
            let err = apply([id], enabled: enabled, configure: configure)
            if err != .success { failures[id] = err }
        }
        return failures
    }

    private static func apply(_ ids: [CGDirectDisplayID], enabled: Bool, configure: ConfigureEnabled) -> CGError {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success else { return err }
        for id in ids {
            err = configure(config, id, enabled)
            if err != .success {
                CGCancelDisplayConfiguration(config)
                return err
            }
        }
        return CGCompleteDisplayConfiguration(config, .forSession)
    }
}
