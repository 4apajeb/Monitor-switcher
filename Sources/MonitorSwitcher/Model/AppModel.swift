import AppKit
import CoreGraphics
import Foundation
import Observation
import ServiceManagement

struct LogEntry: Identifiable {
    enum Level { case info, success, warning, error, device }

    let id = UUID()
    let date: Date
    let level: Level
    let text: String
}

enum DDCStatus: Equatable {
    case checking
    case works(input: UInt16)
    case noReply
    case unavailable
}

/// A display that is currently connected to (and enabled on) the Mac.
struct DisplayState: Identifiable, Equatable {
    let uuid: String
    let name: String
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let pnpID: String
    var ddc: DDCStatus
    var id: String { uuid }
}

struct DeviceRow: Identifiable {
    let key: String
    let name: String
    let kind: DeviceKind
    let transport: String?
    let isConnected: Bool
    let isTrigger: Bool
    var id: String { key }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    var config: AppConfig {
        didSet { if config != oldValue { ConfigStore.save(config) } }
    }

    private(set) var mode: Mode = .mac
    private(set) var isSwitching = false
    private(set) var devices: [String: HIDDevice] = [:]
    private(set) var displays: [DisplayState] = []
    private(set) var log: [LogEntry] = []
    private(set) var pendingNote: String?
    private(set) var deviceKinds: [String: DeviceKind] = [:]
    private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    private(set) var testingMonitor: String?

    // PC (Monitor Switcher for Windows)
    private(set) var pcOnline: Bool?
    private(set) var pcMonitors: [PCMonitor] = []
    private(set) var pcVersion: String?
    private(set) var pcError: String?
    private(set) var discoveredPCs: [DiscoveredPC] = []
    private(set) var isDiscovering = false
    private(set) var pairingHost: String?
    private(set) var pairingError: String?
    private(set) var serverError: String?
    let macName = Host.current().localizedName ?? "Mac"

    @ObservationIgnored private let server = MacServer()
    @ObservationIgnored private var pcPollTimer: Timer?
    @ObservationIgnored private var lastIgnoredPCInputLog = Date.distantPast
    @ObservationIgnored private let hid = HIDMonitor()
    @ObservationIgnored private let worker = DispatchQueue(label: "MonitorSwitcher.worker", qos: .userInitiated)
    @ObservationIgnored private var pendingSwitch: DispatchWorkItem?
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var lastWake = Date.distantPast
    @ObservationIgnored private var started = false
    @ObservationIgnored private let logHandle: FileHandle?
    @ObservationIgnored private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let logURL: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MonitorSwitcher.log")

    init() {
        config = ConfigStore.load()
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: Self.logURL)
        _ = try? logHandle?.seekToEnd()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        addLog(.info, "Monitor Switcher запущено")

        hid.onChange = { [weak self] change in self?.handle(change) }
        hid.start()
        devices = hid.devices

        worker.async { [weak self] in
            let kinds = SystemInfo.bluetoothDeviceKinds()
            DispatchQueue.main.async {
                self?.deviceKinds = kinds
                self?.completeFirstRunSetup()
            }
        }

        // Displays the app turned off before a quit/crash are restored as soon as we know
        // the user is at the Mac; otherwise we are still in PC mode.
        if !config.cutDisplays.isEmpty {
            if anyTriggerConnected || config.triggers.isEmpty {
                switchTo(.mac, reason: "після перезапуску знайдено монітори без сигналу Mac")
            } else {
                mode = .pc
                addLog(.info, "Продовжую в режимі ПК")
            }
        }

        refreshDisplays()
        observeSystem()
        refreshLoginItem()
        startServer()
        refreshPC()
        pcPollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshPC() }
        if config.launchAtLoginWanted, loginItemStatus == .notRegistered {
            setLaunchAtLogin(true, quiet: true)
        }
    }

    private func completeFirstRunSetup() {
        guard !config.hasCompletedSetup else { return }
        if config.triggers.isEmpty {
            let picks = devices.values
                .filter { $0.isBluetooth && [.keyboard, .mouse].contains(kind(of: $0.name)) }
                .sorted { kind(of: $0.name) == .keyboard && kind(of: $1.name) != .keyboard }
            config.triggers = picks.map { TriggerDevice(key: $0.key, name: $0.name) }
            if !picks.isEmpty {
                addLog(.info, "Тригери: " + picks.map(\.name).joined(separator: ", "))
            }
        }
        config.hasCompletedSetup = true
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            systemAsleep = true
            cancelPendingSwitch()
            addLog(.info, "Mac засинає")
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            systemAsleep = false
            lastWake = Date()
            addLog(.info, "Mac прокинувся")
            scheduleDisplayRefresh(after: 3)
        }

        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let model = Unmanaged<AppModel>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { model.scheduleDisplayRefresh(after: 1.5) }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    // MARK: - Devices

    func kind(of name: String) -> DeviceKind {
        if let kind = deviceKinds[name] { return kind }
        let lower = name.lowercased()
        if lower.contains("mouse") { return .mouse }
        if lower.contains("keyboard") || lower.contains("keys") { return .keyboard }
        return .other
    }

    func isTrigger(_ key: String) -> Bool { config.triggers.contains { $0.key == key } }

    var anyTriggerConnected: Bool { config.triggers.contains { devices[$0.key] != nil } }

    var deviceRows: [DeviceRow] {
        var rows = devices.values.map { d in
            DeviceRow(key: d.key, name: d.name, kind: kind(of: d.name), transport: d.transport,
                      isConnected: true, isTrigger: isTrigger(d.key))
        }
        for t in config.triggers where devices[t.key] == nil {
            rows.append(DeviceRow(key: t.key, name: t.name, kind: kind(of: t.name), transport: nil,
                                  isConnected: false, isTrigger: true))
        }
        return rows.sorted {
            if $0.isTrigger != $1.isTrigger { return $0.isTrigger }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    var triggerRows: [DeviceRow] { deviceRows.filter(\.isTrigger) }

    func setTrigger(_ row: DeviceRow, enabled: Bool) {
        if enabled {
            guard !isTrigger(row.key) else { return }
            config.triggers.append(TriggerDevice(key: row.key, name: row.name))
        } else {
            config.triggers.removeAll { $0.key == row.key }
        }
    }

    private func handle(_ change: HIDChange) {
        devices = hid.devices
        switch change {
        case let .connected(device):
            guard isTrigger(device.key) else { return }
            addLog(.device, "\(device.name) підключилась до Mac")
            cancelPendingSwitch()
            guard config.automationEnabled else { return }
            if mode == .pc || (!config.cutDisplays.isEmpty && !isSwitching) {
                switchTo(.mac, reason: "\(device.name) знову з Mac")
            }

        case let .disconnected(device):
            guard isTrigger(device.key) else { return }
            let idle = SystemInfo.idleSeconds()
            addLog(.device, "\(device.name) відключилась від Mac (без дій \(formatSeconds(idle)))")
            guard config.automationEnabled, mode == .mac else { return }
            cancelPendingSwitch()

            // With the PC app paired, the PC itself reports when you actually start using it,
            // so a keyboard that merely fell asleep can never switch the monitors.
            if let pc = config.pc {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let reachable = (try? PCClient.call(pc, "/hello", timeout: 1.5).get()) != nil
                    DispatchQueue.main.async {
                        guard let self, self.mode == .mac else { return }
                        self.pcOnline = reachable
                        if reachable {
                            self.addLog(.info, "Чекаю, поки ви почнете працювати на ПК")
                        } else {
                            self.addLog(.warning, "ПК не відповідає — вирішую сам, без нього")
                            self.scheduleHeuristicSwitch(after: device, idle: idle)
                        }
                    }
                }
                return
            }
            scheduleHeuristicSwitch(after: device, idle: idle)
        }
    }

    private func scheduleHeuristicSwitch(after device: HIDDevice, idle: TimeInterval) {
        cancelPendingSwitch()
        pendingNote = "\(device.name) відключилась — перевіряю…"
        let work = DispatchWorkItem { [weak self] in self?.decideSwitchToPC(after: device, idle: idle) }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.disconnectDelay, execute: work)
    }

    /// The PC app saw keyboard/mouse input on the PC.
    private func handlePCInput() -> Bool {
        guard config.automationEnabled, mode == .mac, !isSwitching else { return false }
        let leftMac = config.triggers.isEmpty || config.triggers.contains { devices[$0.key] == nil }
        guard leftMac else {
            if Date().timeIntervalSince(lastIgnoredPCInputLog) > 60 {
                lastIgnoredPCInputLog = Date()
                addLog(.info, "Хтось користується ПК, але клавіатура й миша ще з Mac — не перемикаю")
            }
            return false
        }
        switchTo(.pc, reason: "ви почали працювати на ПК")
        return true
    }

    private func cancelPendingSwitch() {
        pendingSwitch?.cancel()
        pendingSwitch = nil
        pendingNote = nil
    }

    private func decideSwitchToPC(after device: HIDDevice, idle: TimeInterval) {
        pendingSwitch = nil
        pendingNote = nil
        guard config.automationEnabled, mode == .mac else { return }
        if systemAsleep || Date().timeIntervalSince(lastWake) < 20 {
            addLog(.info, "Mac засинав або щойно прокинувся — не перемикаю")
            return
        }
        let stillHere = config.triggers.filter { devices[$0.key] != nil }
        if config.triggerRule == .all, !stillHere.isEmpty {
            addLog(.info, "Чекаю, доки відключиться й " + stillHere.map(\.name).joined(separator: ", "))
            return
        }
        if config.activityGuard, idle > config.activityWindow {
            addLog(.info, "Схоже, \(device.name) просто заснула (Mac без дій \(formatSeconds(idle))) — не перемикаю")
            return
        }
        switchTo(.pc, reason: "\(device.name) перейшла на ПК")
    }

    // MARK: - Displays

    func scheduleDisplayRefresh(after delay: TimeInterval) {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDisplays() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func refreshDisplays() {
        worker.async { [weak self] in
            let probe = DDCTiming(writeCycles: 1, writeDelay: 10_000, readDelay: 50_000, retries: 3)
            let states = DisplayDiscovery.externalDisplays().map { display -> DisplayState in
                let status: DDCStatus
                if !display.hasDDCTransport {
                    status = .unavailable
                } else if let value = try? DDC.read(display, vcp: VCP.inputSource, timing: probe) {
                    status = .works(input: value.current)
                } else {
                    status = .noReply
                }
                return DisplayState(uuid: display.uuid, name: display.name, displayID: display.displayID,
                                    frame: CGDisplayBounds(display.displayID), pnpID: display.pnpID, ddc: status)
            }
            DispatchQueue.main.async {
                self?.displays = states
                self?.syncRules()
            }
        }
    }

    func display(for rule: MonitorRule) -> DisplayState? { displays.first { $0.uuid == rule.uuid } }

    func isCut(_ rule: MonitorRule) -> Bool { config.cutDisplays.contains { $0.uuid == rule.uuid } }

    private func syncRules() {
        var monitors = config.monitors
        for state in displays {
            if let index = monitors.firstIndex(where: { $0.uuid == state.uuid }) {
                monitors[index].displayID = state.displayID
                monitors[index].frame = state.frame
                monitors[index].name = state.name
                monitors[index].pnpID = state.pnpID
            } else {
                var rule: MonitorRule
                if case let .works(input) = state.ddc {
                    rule = MonitorRule(uuid: state.uuid, name: state.name, method: .ddc, macInput: input,
                                       pcInput: input == 15 ? 17 : 15, displayID: state.displayID, frame: state.frame)
                } else {
                    rule = MonitorRule(uuid: state.uuid, name: state.name, method: .cutSignal, macInput: 18,
                                       pcInput: 15, displayID: state.displayID, frame: state.frame)
                }
                rule.pnpID = state.pnpID
                monitors.append(rule)
                addLog(.info, "Новий монітор: \(state.name) — спосіб «\(rule.method.title)»")
            }
        }
        if monitors != config.monitors { config.monitors = monitors }
    }

    func forget(_ rule: MonitorRule) {
        config.monitors.removeAll { $0.uuid == rule.uuid }
    }

    // MARK: - Switching

    func toggle() { switchTo(mode == .mac ? .pc : .mac, reason: "вручну") }

    func switchTo(_ target: Mode, reason: String) {
        cancelPendingSwitch()
        let rules = config.monitors
        let pc = config.pc
        mode = target
        isSwitching = true
        addLog(target == .pc ? .info : .info, "Перемикаю на \(target.title): \(reason)")

        var toCut: [CutDisplay] = []
        var toRestore: [CutDisplay] = []
        if target == .pc {
            toCut = displaysToCut(rules)
            var remembered = config.cutDisplays
            for c in toCut where !remembered.contains(where: { $0.displayID == c.displayID }) {
                remembered.append(c)
            }
            config.cutDisplays = remembered // saved to disk before anything is turned off
        } else {
            toRestore = config.cutDisplays
        }

        worker.async { [weak self] in
            var notes: [(Date, LogEntry.Level, String)] = []
            var restoreFailures: Set<UInt32> = []
            var cutFailures: Set<UInt32> = []

            // DDC first: it takes a fraction of a second, while turning displays on/off
            // makes macOS reconfigure the whole desktop.
            var started = Date()
            let found = DisplayDiscovery.externalDisplays()
            for rule in rules where rule.method == .ddc {
                let (level, text) = Self.applyDDC(rule, target: target, found: found)
                notes.append((Date(), level, text + Self.elapsed(since: started)))
            }
            for rule in rules where rule.method == .pcHelper {
                started = Date()
                let (level, text) = Self.applyViaPC(rule, target: target, pc: pc)
                notes.append((Date(), level, text + Self.elapsed(since: started)))
            }

            if !toRestore.isEmpty {
                started = Date()
                let failures = DisplayOutput.set(toRestore.map(\.displayID), enabled: true)
                restoreFailures = Set(failures.keys)
                for c in toRestore {
                    if let err = failures[c.displayID] {
                        notes.append((Date(), .error, "\(c.name): не вдалося ввімкнути сигнал (код \(err.rawValue))"))
                    } else {
                        notes.append((Date(), .success, "\(c.name): сигнал Mac увімкнено" + Self.elapsed(since: started)))
                    }
                }
            }

            if !toCut.isEmpty {
                started = Date()
                let failures = DisplayOutput.set(toCut.map(\.displayID), enabled: false)
                cutFailures = Set(failures.keys)
                for c in toCut {
                    if let err = failures[c.displayID] {
                        notes.append((Date(), .error, "\(c.name): не вдалося вимкнути сигнал (код \(err.rawValue))"))
                    } else {
                        notes.append((Date(), .success, "\(c.name): сигнал Mac вимкнено" + Self.elapsed(since: started)))
                    }
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                for (date, level, text) in notes { self.addLog(level, text, date: date) }
                if target == .mac {
                    self.config.cutDisplays.removeAll { c in
                        toRestore.contains(c) && !restoreFailures.contains(c.displayID)
                    }
                } else {
                    self.config.cutDisplays.removeAll { cutFailures.contains($0.displayID) }
                }
                self.isSwitching = false
                self.scheduleDisplayRefresh(after: 2.5)
            }

            // Let the PC app know who owns the monitors now (best effort).
            if let pc {
                _ = PCClient.call(pc, "/mode", ["mode": target.rawValue], timeout: 2)
            }
        }
    }

    private static func applyViaPC(_ rule: MonitorRule, target: Mode, pc: PairedPC?) -> (LogEntry.Level, String) {
        let value = target == .pc ? rule.pcInput : rule.macInput
        guard let pc else { return (.error, "\(rule.name): ПК не підключено — сторінка «ПК»") }
        guard let id = rule.pcID ?? rule.pnpID else { return (.error, "\(rule.name): невідомий ідентифікатор монітора") }
        switch PCClient.call(pc, "/input", ["monitor": id, "name": rule.name, "value": String(value)], timeout: 5) {
        case .success:
            return (.success, "\(rule.name) → \(InputSource.name(value)) (через ПК)")
        case let .failure(error):
            return (.error, "\(rule.name): \(error)")
        }
    }

    private func displaysToCut(_ rules: [MonitorRule]) -> [CutDisplay] {
        let active = DisplayOutput.activeDisplayIDs()
        var candidates = rules.filter { $0.method == .cutSignal }.compactMap { rule -> CutDisplay? in
            guard let id = rule.displayID, active.contains(id) else { return nil }
            return CutDisplay(uuid: rule.uuid, displayID: id, name: rule.name)
        }
        if !candidates.isEmpty, candidates.count >= active.count {
            let kept = candidates.removeLast()
            addLog(.warning, "Mac не може лишитися зовсім без екранів — \(kept.name) не вимикаю")
        }
        return candidates
    }

    private static func elapsed(since start: Date) -> String {
        String(format: " (%.1f с)", Date().timeIntervalSince(start))
    }

    private static func applyDDC(_ rule: MonitorRule, target: Mode, found: [ExternalDisplay]) -> (LogEntry.Level, String) {
        let value = target == .pc ? rule.pcInput : rule.macInput
        guard let display = found.first(where: { $0.uuid == rule.uuid }) else {
            return (.warning, "\(rule.name): не підключений до Mac")
        }
        do {
            try DDC.write(display, vcp: VCP.inputSource, value: value, timing: .patient)
            return (.success, "\(rule.name) → \(InputSource.name(value))")
        } catch {
            return (.error, "\(rule.name): \(error)")
        }
    }

    /// Switches one monitor to the PC for a few seconds and back — to check the settings.
    func testMonitor(_ rule: MonitorRule, seconds: Double = 5) {
        guard testingMonitor == nil, !isSwitching, rule.method != .ignore else { return }
        if rule.method == .cutSignal, displaysToCut([rule]).isEmpty {
            addLog(.warning, "\(rule.name): зараз немає сигналу Mac, перевірити не можу")
            return
        }
        testingMonitor = rule.uuid
        addLog(.info, "Перевірка: \(rule.name) → ПК на \(Int(seconds)) с")
        let pc = config.pc
        worker.async { [weak self] in
            var notes: [(LogEntry.Level, String)] = []
            if rule.method == .pcHelper {
                notes.append(Self.applyViaPC(rule, target: .pc, pc: pc))
                Thread.sleep(forTimeInterval: seconds)
                notes.append(Self.applyViaPC(rule, target: .mac, pc: pc))
            } else if rule.method == .ddc {
                notes.append(Self.applyDDC(rule, target: .pc, found: DisplayDiscovery.externalDisplays()))
                Thread.sleep(forTimeInterval: seconds)
                notes.append(Self.applyDDC(rule, target: .mac, found: DisplayDiscovery.externalDisplays()))
            } else if let id = rule.displayID {
                let off = DisplayOutput.set([id], enabled: false)
                notes.append(off.isEmpty ? (.success, "\(rule.name): сигнал вимкнено") : (.error, "\(rule.name): не вдалося вимкнути сигнал"))
                Thread.sleep(forTimeInterval: seconds)
                let on = DisplayOutput.set([id], enabled: true)
                notes.append(on.isEmpty ? (.success, "\(rule.name): сигнал увімкнено") : (.error, "\(rule.name): не вдалося ввімкнути сигнал — натисніть «Повернути всі монітори»"))
            }
            DispatchQueue.main.async {
                for (level, text) in notes { self?.addLog(level, text) }
                self?.testingMonitor = nil
                self?.scheduleDisplayRefresh(after: 2.5)
            }
        }
    }

    /// Emergency: turns the Mac signal on for every monitor the app may have turned off and
    /// sends every DDC monitor back to its Mac input.
    func restoreEverything() {
        let online = Set(DisplayOutput.onlineDisplayIDs())
        var extra: [CutDisplay] = []
        for rule in config.monitors where rule.method == .cutSignal {
            if let id = rule.displayID, !online.contains(id), !config.cutDisplays.contains(where: { $0.displayID == id }) {
                extra.append(CutDisplay(uuid: rule.uuid, displayID: id, name: rule.name))
            }
        }
        config.cutDisplays.append(contentsOf: extra)
        switchTo(.mac, reason: "аварійне відновлення")
    }

    func handle(url: URL) -> Bool {
        switch (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "mac": switchTo(.mac, reason: "команда \(url.absoluteString)")
        case "pc": switchTo(.pc, reason: "команда \(url.absoluteString)")
        case "toggle": toggle()
        case "restore": restoreEverything()
        case "auto-on": config.automationEnabled = true
        case "auto-off": config.automationEnabled = false
        case "show": return true
        default: addLog(.warning, "Невідома команда: \(url.absoluteString)")
        }
        return false
    }

    // MARK: - PC app

    var windowsAppURL: URL? { Bundle.main.url(forResource: "MonitorSwitcher", withExtension: "exe") }

    var downloadLinks: [String] { NetworkInfo.localIPv4().map { "http://\($0):\(NetworkInfo.macPort)" } }

    func pcMonitor(for rule: MonitorRule) -> PCMonitor? {
        Self.match(rule, in: pcMonitors)
    }

    private static func match(_ rule: MonitorRule, in monitors: [PCMonitor]) -> PCMonitor? {
        func same(_ a: String?, _ b: String) -> Bool { a.map { $0.caseInsensitiveCompare(b) == .orderedSame } ?? false }
        return monitors.first { same(rule.pnpID, $0.id) }
            ?? monitors.first { same(rule.name, $0.name) }
            ?? monitors.first { same(rule.pcID, $0.id) }
    }

    /// Remembers which PC monitor id belongs to each rule, so switching works even when the
    /// PC's status can't be fetched at that moment.
    private func syncPCIDs() {
        var monitors = config.monitors
        for index in monitors.indices {
            if let match = Self.match(monitors[index], in: pcMonitors), monitors[index].pcID != match.id {
                monitors[index].pcID = match.id
            }
        }
        if monitors != config.monitors { config.monitors = monitors }
    }

    private func startServer() {
        server.handler = { [weak self] path, query, remote, respond in
            DispatchQueue.main.async {
                guard let self else { return respond(.json(["ok": false], status: 500)) }
                respond(self.serve(path: path, query: query, remote: remote))
            }
        }
        do {
            try server.start()
        } catch {
            serverError = "Порт \(NetworkInfo.macPort) зайнятий: \(error.localizedDescription)"
            addLog(.error, serverError!)
        }
    }

    private func serve(path: String, query: [String: String], remote: String) -> HTTPResponse {
        switch path {
        case "/", "/index.html":
            return .html(Self.downloadPage(macName: macName, hasExe: windowsAppURL != nil))
        case "/download", "/MonitorSwitcher.exe":
            guard let url = windowsAppURL, let data = try? Data(contentsOf: url) else {
                return .json(["ok": false, "error": "exe не знайдено"], status: 404)
            }
            addLog(.info, "ПК \(remote) завантажує Monitor Switcher для Windows")
            return HTTPResponse(body: data, contentType: "application/octet-stream", filename: "MonitorSwitcher.exe")
        case "/hello":
            return .json(["ok": true, "name": macName, "app": "mac"])
        default:
            break
        }

        guard var pc = config.pc, query["token"] == pc.token else {
            return .json(["ok": false, "error": "Mac не впізнає цей ПК"], status: 403)
        }
        if !remote.isEmpty, pc.host != remote {
            pc.host = remote
            config.pc = pc
        }
        pcOnline = true

        switch path {
        case "/status":
            return .json(["ok": true, "name": macName, "mode": mode.rawValue, "automation": config.automationEnabled])
        case "/switch":
            let target: Mode = query["mode"] == "pc" ? .pc : .mac
            if target != mode || target == .mac && !config.cutDisplays.isEmpty {
                switchTo(target, reason: "команда з ПК")
            }
            return .json(["ok": true, "mode": mode.rawValue])
        case "/pc-input":
            let switched = handlePCInput()
            return .json(["ok": true, "mode": mode.rawValue, "switched": switched])
        case "/unpair":
            addLog(.warning, "ПК \(pc.name) від'єднався")
            config.pc = nil
            pcOnline = nil
            pcMonitors = []
            return .json(["ok": true])
        default:
            return .json(["ok": false, "error": "невідомий запит"], status: 404)
        }
    }

    func refreshPC() {
        guard let pc = config.pc else { pcOnline = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = PCClient.call(pc, "/status", timeout: 6)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(json):
                    if self.pcOnline != true { self.addLog(.success, "ПК \(pc.name) на зв'язку") }
                    self.pcOnline = true
                    self.pcError = nil
                    self.pcMonitors = PCClient.monitors(from: json)
                    self.pcVersion = json["version"] as? String
                    self.syncPCIDs()
                case let .failure(error):
                    if self.pcOnline == true { self.addLog(.warning, "ПК \(pc.name) не відповідає") }
                    self.pcOnline = false
                    self.pcError = error.description
                }
            }
        }
    }

    func discoverPCs() {
        guard !isDiscovering else { return }
        isDiscovering = true
        pairingError = nil
        let name = macName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = PCClient.discover(macName: name, timeout: 2.5)
            DispatchQueue.main.async {
                self?.discoveredPCs = found
                self?.isDiscovering = false
                if found.isEmpty {
                    self?.pairingError = "ПК не знайдено. Перевірте, що Monitor Switcher запущений на ПК, а Windows дозволила йому доступ до мережі. Можна ввести IP-адресу ПК вручну."
                }
            }
        }
    }

    func pair(host: String, port: Int = NetworkInfo.pcPort) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, pairingHost == nil else { return }
        pairingHost = host
        pairingError = nil
        addLog(.info, "Підключаюсь до ПК \(host) — підтвердіть на ПК")
        let name = macName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PCClient.get(host: host, port: port, path: "/pair",
                                      query: ["mac": name, "port": String(NetworkInfo.macPort)], timeout: 95)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pairingHost = nil
                switch result {
                case let .success(json):
                    guard let token = json["token"] as? String else {
                        self.pairingError = "ПК не надіслав ключ"
                        return
                    }
                    let pcName = json["name"] as? String ?? host
                    self.config.pc = PairedPC(name: pcName, host: host, port: port, token: token)
                    self.discoveredPCs = []
                    self.addLog(.success, "ПК \(pcName) підключено")
                    self.refreshPC()
                case let .failure(error):
                    self.pairingError = error.description
                    self.addLog(.error, "Не вдалося підключити ПК: \(error)")
                }
            }
        }
    }

    func unpairPC() {
        guard let pc = config.pc else { return }
        DispatchQueue.global().async { _ = PCClient.call(pc, "/unpair", timeout: 2) }
        config.pc = nil
        pcOnline = nil
        pcMonitors = []
        addLog(.info, "ПК \(pc.name) від'єднано")
    }

    private static func downloadPage(macName: String, hasExe: Bool) -> String {
        """
        <!doctype html><html lang="uk"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Monitor Switcher для Windows</title>
        <style>
        body{margin:0;font-family:"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;background:#1f1f1f;color:#f3f3f3;display:grid;place-items:center;min-height:100vh}
        .card{background:#2a2a2a;border:1px solid #383838;border-radius:18px;padding:36px 40px;max-width:520px}
        .logo{width:64px;height:64px;border-radius:16px;background:linear-gradient(135deg,#2979ff,#9e57ff);display:grid;place-items:center;font-size:32px}
        h1{font-size:26px;margin:20px 0 8px} p{color:#a3a3a3;line-height:1.55}
        a.btn{display:inline-block;margin-top:18px;padding:12px 22px;border-radius:10px;background:#4c8dff;color:#fff;text-decoration:none;font-weight:600}
        ol{color:#a3a3a3;line-height:1.7;padding-left:20px}
        </style></head><body><div class="card">
        <div class="logo">🖥️</div>
        <h1>Monitor Switcher для Windows</h1>
        <p>Цю сторінку віддає Mac «\(macName)». Програма для ПК перемикає монітори разом з Mac і повідомляє йому, коли ви сідаєте за ПК.</p>
        \(hasExe ? "<a class=\"btn\" href=\"/download\">Завантажити MonitorSwitcher.exe</a>" : "<p>Файл програми не вбудовано в цю збірку Mac-застосунку.</p>")
        <ol><li>Запустіть завантажений файл. Якщо Windows покаже «Windows захистила ваш ПК» — «Докладніше» → «Однаково запустити».</li>
        <li>Дозвольте доступ до приватної мережі, якщо з'явиться запит брандмауера.</li>
        <li>На Mac: Monitor Switcher → «ПК» → «Знайти ПК» і підтвердіть підключення на ПК.</li></ol>
        </div></body></html>
        """
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    func refreshLoginItem() { loginItemStatus = SMAppService.mainApp.status }

    func setLaunchAtLogin(_ enabled: Bool, quiet: Bool = false) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            config.launchAtLoginWanted = enabled
        } catch {
            addLog(.error, "Автозапуск: \(error.localizedDescription)")
        }
        refreshLoginItem()
        if !quiet || loginItemStatus != (enabled ? .enabled : .notRegistered) {
            addLog(.info, "Автозапуск: \(loginItemStatusText)")
        }
    }

    var loginItemStatusText: String {
        switch loginItemStatus {
        case .enabled: return "увімкнено"
        case .notRegistered: return "вимкнено"
        case .requiresApproval: return "чекає підтвердження в Параметрах системи"
        case .notFound: return "macOS не знайшла застосунок (код notFound)"
        @unknown default: return "невідомий стан \(loginItemStatus.rawValue)"
        }
    }

    // MARK: - Log

    func addLog(_ level: LogEntry.Level, _ text: String, date: Date = Date()) {
        let entry = LogEntry(date: date, level: level, text: text)
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        let line = "\(timeFormatter.string(from: entry.date)) [\(level)] \(text)\n"
        logHandle?.write(Data(line.utf8))
    }

    func clearLog() { log.removeAll() }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) с" : "\(Int((seconds / 60).rounded())) хв"
    }
}
