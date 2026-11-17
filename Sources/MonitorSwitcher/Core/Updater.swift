import AppKit
import Foundation

struct ReleaseInfo: Equatable {
    let version: String
    let tag: String
    let notes: String
    let pageURL: URL?
    let macAssetURL: URL?
    let windowsAssetURL: URL?
}

enum UpdateError: Error, CustomStringConvertible {
    case network(String)
    case noAsset
    case invalidPackage(String)
    case notWritable(String)

    var description: String {
        switch self {
        case let .network(message): return "Couldn't reach GitHub: \(message)"
        case .noAsset: return "The release has no macOS package"
        case let .invalidPackage(message): return "The downloaded update is invalid: \(message)"
        case let .notWritable(path): return "No permission to replace \(path)"
        }
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Numeric comparison of dotted versions: 1.2.10 > 1.2.9.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = numbers(candidate), b = numbers(installed)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

/// Self-update from GitHub Releases: finds the latest release, downloads the macOS zip,
/// checks it, and swaps the app bundle after this process quits.
enum Updater {
    static let macAssetName = "MonitorSwitcher-macOS.zip"
    static let windowsAssetName = "MonitorSwitcher.exe"

    /// "owner/repo" — set in Info.plist so forks update from their own releases.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "MSUpdateRepository") as? String ?? "4apajeb/Monitor-switcher"
    }

    static func latestRelease() -> Result<ReleaseInfo, UpdateError> {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return .failure(.network("bad repository name"))
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MonitorSwitcher/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        switch fetch(request) {
        case let .failure(error):
            return .failure(error)
        case let .success(data):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return .failure(.network("unexpected response")) }
            let assets = json["assets"] as? [[String: Any]] ?? []
            func asset(_ name: String) -> URL? {
                (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init)
            }
            return .success(ReleaseInfo(
                version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                tag: tag,
                notes: json["body"] as? String ?? "",
                pageURL: (json["html_url"] as? String).flatMap(URL.init),
                macAssetURL: asset(macAssetName),
                windowsAssetURL: asset(windowsAssetName)
            ))
        }
    }

    /// Downloads and verifies the update, then starts a helper that replaces the app once this
    /// process exits and launches the new version. The caller should quit right after.
    static func prepareInstall(_ release: ReleaseInfo) -> Result<Void, UpdateError> {
        guard let assetURL = release.macAssetURL else { return .failure(.noAsset) }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return .failure(.notWritable(parent.path))
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorSwitcher-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return .failure(.invalidPackage(error.localizedDescription))
        }

        var request = URLRequest(url: assetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("MonitorSwitcher/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        let zip = work.appendingPathComponent("update.zip")
        switch fetch(request) {
        case let .failure(error): return .failure(error)
        case let .success(data):
            do { try data.write(to: zip) } catch { return .failure(.invalidPackage(error.localizedDescription)) }
        }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]) == 0 else {
            return .failure(.invalidPackage("can't unzip"))
        }
        guard let newApp = (try? FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }),
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        else { return .failure(.invalidPackage("no app inside")) }

        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            return .failure(.invalidPackage("different bundle identifier"))
        }
        guard let newVersion = info["CFBundleShortVersionString"] as? String,
              !AppVersion.isNewer(AppVersion.current, than: newVersion)
        else { return .failure(.invalidPackage("older version")) }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            return .failure(.invalidPackage("code signature check failed"))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        let script = work.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # Waits for Monitor Switcher to quit, swaps the app bundle and starts the new version.
        PID="$1"; NEW="$2"; TARGET="$3"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.1; i=$((i+1)); done
        BACKUP="${TARGET%.app}.previous.app"
        rm -rf "$BACKUP"
        if mv "$TARGET" "$BACKUP" && mv "$NEW" "$TARGET"; then
            rm -rf "$BACKUP"
        elif [ -d "$BACKUP" ] && [ ! -d "$TARGET" ]; then
            mv "$BACKUP" "$TARGET"
        fi
        open -g "$TARGET" --args --updated
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.invalidPackage(error.localizedDescription))
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        helper.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            return .failure(.invalidPackage("can't start installer: \(error.localizedDescription)"))
        }
        return .success(())
    }

    private static func fetch(_ request: URLRequest) -> Result<Data, UpdateError> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, UpdateError> = .failure(.network("timed out"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(.network(status == 404 ? "no releases yet" : "HTTP \(status)"))
            } else if let data {
                result = .success(data)
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 5)
        return result
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
