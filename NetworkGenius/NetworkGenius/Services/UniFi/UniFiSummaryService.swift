import Foundation

final class UniFiSummaryService {
    private let queryService: UniFiQueryService

    init(queryService: UniFiQueryService) {
        self.queryService = queryService
    }

    /// Builds one of the high-level UniFi summaries exposed to the chat tools.
    func summary(_ name: String) async throws -> String {
        switch name {
        case "overview": return try await overviewSummary()
        case "clients": return try await clientsSummary()
        case "wifi": return try await wifiSummary()
        case "firewall": return try await firewallSummary()
        case "security": return try await securitySummary()
        default: return "Unknown summary: \(name)"
        }
    }

    /// Builds the overall network summary from devices, clients, WiFi, and security data.
    private func overviewSummary() async throws -> String {
        async let sitesResult = queryService.queryItems("sites")
        async let devicesResult = queryService.queryItems("devices")
        async let clientsResult = queryService.queryItems("clients")
        async let networksResult = queryService.queryItems("networks")
        async let wifiResult = queryService.queryItems("wifi-broadcasts")
        async let pendingResult = queryService.queryItems("pending-devices")

        let sites = try await sitesResult
        let devices = try await devicesResult
        let clients = try await clientsResult
        let networks = try await networksResult
        let wifi = try await wifiResult
        let pending = try await pendingResult

        let deviceMap = Dictionary(uniqueKeysWithValues: devices.compactMap { d -> (String, [String: Any])? in
            guard let id = d["id"] as? String else { return nil }
            return (id, d)
        })

        var uplinkCounts: [String: Int] = [:]
        for client in clients where isActiveClient(client) {
            if let uplinkID = client["uplinkDeviceId"] as? String,
               let device = deviceMap[uplinkID],
               isOnlineDevice(device)
            {
                uplinkCounts[uplinkID, default: 0] += 1
            }
        }

        var lines = [
            "Overview",
            "- sites: \(sites.count)",
            "- devices: \(devices.count)",
            "- clients: \(clients.count)",
            "- networks: \(networks.count)",
            "- wifi broadcasts: \(wifi.count)",
            "- pending devices: \(pending.count)",
        ]

        if !uplinkCounts.isEmpty {
            lines.append("- busiest uplinks:")
            let sorted = uplinkCounts.sorted { $0.value > $1.value }.prefix(5)
            for (deviceID, count) in sorted {
                let device = deviceMap[deviceID]
                let name = safeName(device)
                lines.append("  \(name): \(count)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a client-focused summary with counts, activity, and top devices.
    private func clientsSummary() async throws -> String {
        async let devicesResult = queryService.queryItems("devices")
        async let clientsResult = queryService.queryItems("clients")

        let devices = try await devicesResult
        let clients = try await clientsResult

        let deviceMap = Dictionary(uniqueKeysWithValues: devices.compactMap { d -> (String, [String: Any])? in
            guard let id = d["id"] as? String else { return nil }
            return (id, d)
        })

        var byType: [String: Int] = [:]
        var byAccess: [String: Int] = [:]
        var byUplink: [String: Int] = [:]

        for client in clients where isActiveClient(client) {
            let type = client["type"] as? String ?? "UNKNOWN"
            byType[type, default: 0] += 1
            let access = (client["access"] as? [String: Any])?["type"] as? String ?? "UNKNOWN"
            byAccess[access, default: 0] += 1
            if let uplinkID = client["uplinkDeviceId"] as? String,
               let device = deviceMap[uplinkID],
               isOnlineDevice(device)
            {
                byUplink[uplinkID, default: 0] += 1
            }
        }

        var lines = ["Clients", "- total: \(clients.count)", "- by type:"]
        for (type, count) in byType.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(type): \(count)")
        }
        lines.append("- by access:")
        for (access, count) in byAccess.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(access): \(count)")
        }
        lines.append("- by uplink:")
        for (deviceID, count) in byUplink.sorted(by: { $0.value > $1.value }).prefix(10) {
            let name = safeName(deviceMap[deviceID])
            lines.append("  \(name): \(count)")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a WiFi summary with SSIDs, radio health, and client distribution.
    private func wifiSummary() async throws -> String {
        async let networksResult = queryService.queryItems("networks")
        async let wifiResult = queryService.queryItems("wifi-broadcasts")

        let networks = try await networksResult
        let wifi = try await wifiResult

        let networkMap = Dictionary(uniqueKeysWithValues: networks.compactMap { n -> (String, String)? in
            guard let id = n["id"] as? String else { return nil }
            return (id, n["name"] as? String ?? "unknown network")
        })

        var lines = ["WiFi"]
        for broadcast in wifi {
            let name = safeName(broadcast)
            let enabled = (broadcast["enabled"] as? Bool ?? true) ? "enabled" : "disabled"
            let security = (broadcast["securityConfiguration"] as? [String: Any])?["type"] as? String ?? "UNKNOWN"
            let networkRef = broadcast["network"] as? [String: Any]
            let networkName: String
            if networkRef?["type"] as? String == "SPECIFIC",
               let netID = networkRef?["networkId"] as? String
            {
                networkName = networkMap[netID] ?? "unknown network"
            } else {
                networkName = "native"
            }
            let freqs = broadcast["broadcastingFrequenciesGHz"] as? [Any] ?? []
            let freqLabel = freqs.isEmpty ? "default" : freqs.map { "\($0)" }.joined(separator: ",")
            lines.append("- \(name): \(enabled), security=\(security), network=\(networkName), ghz=\(freqLabel)")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a firewall summary from policy, ACL, and DNS rule data.
    private func firewallSummary() async throws -> String {
        async let policiesResult = queryService.queryItems("firewall-policies")
        async let zonesResult = queryService.queryItems("firewall-zones")

        let policies = try await policiesResult
        let zones = try await zonesResult

        let zoneMap = Dictionary(uniqueKeysWithValues: zones.compactMap { z -> (String, String)? in
            guard let id = z["id"] as? String else { return nil }
            return (id, z["name"] as? String ?? "unknown zone")
        })

        var actions: [String: Int] = [:]
        var zonePairs: [String: Int] = [:]

        for policy in policies {
            let actionObj = policy["action"] as? [String: Any]
            let actionName = actionObj?["type"] as? String ?? "UNKNOWN"
            actions[actionName, default: 0] += 1
            let source = zoneMap[(policy["source"] as? [String: Any])?["zoneId"] as? String ?? ""] ?? "unknown"
            let dest = zoneMap[(policy["destination"] as? [String: Any])?["zoneId"] as? String ?? ""] ?? "unknown"
            zonePairs["\(source) -> \(dest)", default: 0] += 1
        }

        var lines = ["Firewall", "- actions:"]
        for (action, count) in actions.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(action): \(count)")
        }
        lines.append("- top zone pairs:")
        for (pair, count) in zonePairs.sorted(by: { $0.value > $1.value }).prefix(10) {
            lines.append("  \(pair): \(count)")
        }

        return lines.joined(separator: "\n")
    }

    /// Builds a security summary from CyberSecure and threat-related data.
    private func securitySummary() async throws -> String {
        async let aclResult = queryService.queryItems("acl-rules")
        async let dnsResult = queryService.queryItems("dns-policies")
        async let vpnResult = queryService.queryItems("vpn-servers")
        async let s2sResult = queryService.queryItems("site-to-site-vpn")
        async let voucherResult = queryService.queryItems("hotspot-vouchers")
        async let radiusResult = queryService.queryItems("radius-profiles")

        let acl = try await aclResult
        let dns = try await dnsResult
        let vpn = try await vpnResult
        let s2s = try await s2sResult
        let vouchers = try await voucherResult
        let radius = try await radiusResult

        return [
            "Security",
            "- acl rules: \(acl.count)",
            "- dns policies: \(dns.count)",
            "- vpn servers: \(vpn.count)",
            "- site-to-site tunnels: \(s2s.count)",
            "- hotspot vouchers: \(vouchers.count)",
            "- radius profiles: \(radius.count)",
        ].joined(separator: "\n")
    }

    /// Returns the best display name available for a UniFi row.
    private func safeName(_ item: [String: Any]?) -> String {
        item?["name"] as? String ?? item?["model"] as? String ?? "unknown"
    }

    /// Returns true when a client row looks currently active.
    private func isActiveClient(_ client: [String: Any]) -> Bool {
        if let active = client["active"] as? Bool ?? client["isActive"] as? Bool ?? client["is_online"] as? Bool ?? client["isOnline"] as? Bool {
            return active
        }
        let state = (client["state"] as? String ?? client["status"] as? String ?? client["connectionState"] as? String ?? "").lowercased()
        if state.contains("offline") || state.contains("disconnected") || state.contains("inactive") {
            return false
        }
        return true
    }

    /// Returns true when a device row looks currently online.
    private func isOnlineDevice(_ device: [String: Any]) -> Bool {
        let state = (device["state"] as? String ?? device["status"] as? String ?? device["connectionState"] as? String ?? "").lowercased()
        guard !state.isEmpty else { return true }
        return !(state.contains("offline") || state.contains("disconnected") || state.contains("inactive"))
    }
}
