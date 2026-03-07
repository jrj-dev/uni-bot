import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isWiFiConnected = false
    @Published private(set) var isVPNConnected = false
    @Published private(set) var isConsoleReachable = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let vpn = Self.detectActiveVPN(on: path)
            DispatchQueue.main.async {
                self?.isWiFiConnected = wifi
                self?.isVPNConnected = vpn
                debugLog("Path update: wifi=\(wifi), vpn=\(vpn), status=\(path.status == .satisfied ? "satisfied" : "unsatisfied")", category: "Network")
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isOnNetwork: Bool {
        (isWiFiConnected || isVPNConnected) && isConsoleReachable
    }

    func probeConsole(baseURL: String, allowSelfSigned: Bool) async {
        let normalizedBaseURL = UniFiAPIClient.normalizeBaseURL(baseURL)
        guard let url = URL(string: normalizedBaseURL) else {
            debugLog("Console probe skipped: invalid URL '\(baseURL)'", category: "Network")
            isConsoleReachable = false
            return
        }
        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        debugLog("Console probe started: \(normalizedBaseURL) (wifi=\(isWiFiConnected), vpn=\(isVPNConnected))", category: "Network")
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConsoleReachable = (200..<500).contains(code)
            debugLog("Console probe HTTP \(code), reachable=\(isConsoleReachable)", category: "Network")
        } catch {
            isConsoleReachable = false
            debugLog("Console probe failed: \(error.localizedDescription)", category: "Network")
        }
    }

    nonisolated private static func detectActiveVPN(on path: NWPath) -> Bool {
        guard path.status == .satisfied else { return false }
        guard path.usesInterfaceType(.other) else { return false }
        return path.availableInterfaces.contains { interface in
            isLikelyVPNInterface(interface.name.lowercased())
        }
    }

    nonisolated private static func isLikelyVPNInterface(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("utun")
            || interfaceName.hasPrefix("ipsec")
            || interfaceName.hasPrefix("ppp")
            || interfaceName.hasPrefix("tun")
            || interfaceName.hasPrefix("tap")
            || interfaceName.hasPrefix("wg")
            || interfaceName.contains("wireguard")
    }
}
