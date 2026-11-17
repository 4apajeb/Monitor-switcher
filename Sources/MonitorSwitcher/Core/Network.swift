import Darwin
import Foundation
import Network

/// The PC this Mac is paired with (runs Monitor Switcher for Windows).
struct PairedPC: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
    var token: String
}

struct DiscoveredPC: Identifiable, Equatable {
    let name: String
    let host: String
    let port: Int
    let version: String
    let paired: Bool
    var id: String { host }
}

struct PCMonitor: Identifiable, Equatable {
    let id: String // PnP id, e.g. AUS25BA
    let name: String
    let input: Int
    let ddc: Bool
}

enum NetworkInfo {
    static let macPort: UInt16 = 47801
    static let pcPort = 47800

    /// IPv4 addresses of this Mac on Wi-Fi / Ethernet.
    static func localIPv4() -> [String] {
        interfaces().map(\.address)
    }

    static func broadcastAddresses() -> [String] {
        interfaces().compactMap(\.broadcast)
    }

    private static func interfaces() -> [(address: String, broadcast: String?)] {
        var result: [(String, String?)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), (entry.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let ip = string(from: addr)
            guard !ip.hasPrefix("169.254."), !ip.isEmpty else { continue }
            var broadcast: String?
            if (entry.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let dst = entry.ifa_dstaddr {
                broadcast = string(from: dst)
            }
            result.append((ip, broadcast))
        }
        return result
    }

    private static func string(from addr: UnsafeMutablePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var a = sin.pointee.sin_addr
            _ = inet_ntop(AF_INET, &a, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        return String(cString: buffer)
    }
}

// MARK: - Talking to the PC

enum PCClientError: Error, CustomStringConvertible {
    case unreachable(String)
    case rejected(String)
    case badResponse

    var description: String {
        switch self {
        case let .unreachable(message): return "ПК не відповідає (\(message))"
        case let .rejected(message): return message
        case .badResponse: return "незрозуміла відповідь ПК"
        }
    }
}

enum PCClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 100
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Synchronous GET returning the JSON body. Call off the main thread.
    static func get(host: String, port: Int, path: String, query: [String: String] = [:],
                    timeout: TimeInterval = 4) -> Result<[String: Any], PCClientError> {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return .failure(.badResponse) }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], PCClientError> = .failure(.unreachable("тайм-аут"))
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(.unreachable(error.localizedDescription))
                return
            }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(.badResponse)
                return
            }
            if (response as? HTTPURLResponse)?.statusCode == 403 {
                result = .failure(.rejected("ПК не впізнає цей Mac — підключіть ПК заново"))
            } else if json["ok"] as? Bool == false {
                result = .failure(.rejected(json["error"] as? String ?? "ПК повернув помилку"))
            } else {
                result = .success(json)
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return result
    }

    static func call(_ pc: PairedPC, _ path: String, _ query: [String: String] = [:],
                     timeout: TimeInterval = 4) -> Result<[String: Any], PCClientError> {
        var query = query
        query["token"] = pc.token
        return get(host: pc.host, port: pc.port, path: path, query: query, timeout: timeout)
    }

    static func monitors(from json: [String: Any]) -> [PCMonitor] {
        (json["monitors"] as? [[String: Any]] ?? []).map {
            PCMonitor(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                      input: ($0["input"] as? NSNumber)?.intValue ?? -1, ddc: $0["ddc"] as? Bool ?? false)
        }
    }

    /// Finds Monitor Switcher for Windows on the local network (UDP broadcast).
    static func discover(macName: String, timeout: TimeInterval = 2) -> [DiscoveredPC] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let message = Array("MSW-DISCOVER|\(macName)".utf8)
        let targets = Set(NetworkInfo.broadcastAddresses() + ["255.255.255.255"])
        for _ in 0..<2 {
            for target in targets {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(NetworkInfo.pcPort).bigEndian)
                inet_pton(AF_INET, target, &addr.sin_addr)
                _ = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var found: [String: DiscoveredPC] = [:]
        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { continue }
            let parts = String(decoding: buffer[0..<count], as: UTF8.self).split(separator: "|").map(String.init)
            guard parts.first == "MSW-PC", parts.count >= 4 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: ip)
            found[host] = DiscoveredPC(name: parts[1], host: host, port: Int(parts[3]) ?? NetworkInfo.pcPort,
                                       version: parts[2], paired: parts.count > 4 && parts[4] == "paired")
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

// MARK: - The Mac's own small HTTP API (for the PC app and the exe download)

struct HTTPResponse {
    var status = 200
    var body = Data()
    var contentType = "application/json; charset=utf-8"
    var filename: String?

    static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(body: Data(text.utf8), contentType: "text/html; charset=utf-8")
    }
}

final class MacServer {
    typealias Handler = (_ path: String, _ query: [String: String], _ remote: String,
                         _ respond: @escaping (HTTPResponse) -> Void) -> Void

    var handler: Handler?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "MonitorSwitcher.server")

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: NetworkInfo.macPort)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self?.handle(connection, head: buffer[..<end.lowerBound])
            } else if isComplete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self?.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, head: Data) {
        guard let text = String(data: head, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first
        else { connection.cancel(); return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: "http://mac" + parts[1]) else {
            connection.cancel()
            return
        }
        var query: [String: String] = [:]
        components.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        var remote = ""
        if case let .hostPort(host, _) = connection.endpoint { remote = Self.describe(host) }

        guard let handler else { connection.cancel(); return }
        handler(components.path, query, remote) { response in
            var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\n"
            header += "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            if let filename = response.filename {
                header += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
            }
            header += "\r\n"
            var payload = Data(header.utf8)
            payload.append(response.body)
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func describe(_ host: NWEndpoint.Host) -> String {
        var text: String
        switch host {
        case let .ipv4(address): text = "\(address)"
        case let .ipv6(address): text = "\(address)"
        case let .name(name, _): text = name
        @unknown default: text = "\(host)"
        }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return text
    }
}
