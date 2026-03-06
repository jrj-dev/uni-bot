import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isWiFiConnected = false
    @Published private(set) var isConsoleReachable = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                self?.isWiFiConnected = wifi
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isOnNetwork: Bool {
        isWiFiConnected && isConsoleReachable
    }

    func probeConsole(baseURL: String, allowSelfSigned: Bool) async {
        guard let url = URL(string: baseURL) else {
            isConsoleReachable = false
            return
        }
        let session = URLSessionFactory.makeSession(allowSelfSigned: allowSelfSigned)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            isConsoleReachable = (200..<500).contains(code)
        } catch {
            isConsoleReachable = false
        }
    }
}
