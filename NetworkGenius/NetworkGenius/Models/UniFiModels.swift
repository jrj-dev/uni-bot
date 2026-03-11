import Foundation

struct PaginatedResponse<T: Decodable>: Decodable {
    let data: [T]
    let offset: Int?
    let limit: Int?
    let count: Int?
    let totalCount: Int?
}

struct UniFiDevice: Codable, Identifiable {
    let id: String
    let name: String?
    let model: String?
    let state: String?
    let firmwareVersion: String?
    let mac: String?
    let ip: String?
}

struct UniFiClient: Codable, Identifiable {
    let id: String
    let name: String?
    let hostname: String?
    let mac: String?
    let ip: String?
    let type: String?
    let uplinkDeviceId: String?
    let access: UniFiClientAccess?
}

struct UniFiClientAccess: Codable {
    let type: String?
}

struct ClientModificationApproval: Codable, Identifiable, Equatable {
    let approvalKey: String
    var clientID: String
    var name: String
    var hostname: String
    var mac: String
    var ip: String
    var isApproved: Bool
    var isCurrentlyConnected: Bool

    var id: String { approvalKey }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostname.isEmpty { return trimmedHostname }
        let trimmedMAC = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMAC.isEmpty { return trimmedMAC }
        return clientID
    }

    var detailLine: String {
        var parts: [String] = []
        if !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           hostname.trimmingCharacters(in: .whitespacesAndNewlines) != displayName
        {
            parts.append(hostname.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !mac.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(mac.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !ip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(ip.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !isCurrentlyConnected {
            parts.append("offline")
        }
        return parts.joined(separator: " • ")
    }

    static func approvalKey(for client: UniFiClient) -> String {
        let normalizedMAC = normalizeIdentifier(client.mac)
        if !normalizedMAC.isEmpty {
            return normalizedMAC
        }
        return normalizeIdentifier(client.id)
    }

    static func merge(currentClients: [UniFiClient], existing: [ClientModificationApproval]) -> [ClientModificationApproval] {
        var mergedByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.approvalKey, $0) })

        for client in currentClients {
            let key = approvalKey(for: client)
            guard !key.isEmpty else { continue }
            let previous = mergedByKey[key]
            mergedByKey[key] = ClientModificationApproval(
                approvalKey: key,
                clientID: client.id,
                name: preferred(current: client.name, fallback: previous?.name),
                hostname: preferred(current: client.hostname, fallback: previous?.hostname),
                mac: preferred(current: client.mac, fallback: previous?.mac),
                ip: preferred(current: client.ip, fallback: previous?.ip),
                isApproved: previous?.isApproved ?? false,
                isCurrentlyConnected: true
            )
        }

        for entry in existing where mergedByKey[entry.approvalKey] == nil {
            var staleEntry = entry
            staleEntry.isCurrentlyConnected = false
            mergedByKey[entry.approvalKey] = staleEntry
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.isApproved != rhs.isApproved {
                return lhs.isApproved && !rhs.isApproved
            }
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func preferred(current: String?, fallback: String?) -> String {
        let cleanedCurrent = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedCurrent.isEmpty { return cleanedCurrent }
        return fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func normalizeIdentifier(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct UniFiNetwork: Codable, Identifiable {
    let id: String
    let name: String?
    let vlanId: Int?
    let enabled: Bool?
    let `default`: Bool?
}

struct UniFiWiFiBroadcast: Codable, Identifiable {
    let id: String
    let name: String?
    let enabled: Bool?
    let securityConfiguration: WiFiSecurity?
    let broadcastingFrequenciesGHz: [Double]?
    let network: WiFiNetworkRef?
}

struct WiFiSecurity: Codable {
    let type: String?
}

struct WiFiNetworkRef: Codable {
    let type: String?
    let networkId: String?
}

struct UniFiFirewallPolicy: Codable, Identifiable {
    let id: String
    let name: String?
    let action: FirewallAction?
    let source: FirewallEndpoint?
    let destination: FirewallEndpoint?
}

struct FirewallAction: Codable {
    let type: String?
}

struct FirewallEndpoint: Codable {
    let zoneId: String?
}

struct UniFiFirewallZone: Codable, Identifiable {
    let id: String
    let name: String?
}

struct UniFiACLRule: Codable, Identifiable {
    let id: String
    let name: String?
}

struct UniFiDNSPolicy: Codable, Identifiable {
    let id: String
    let name: String?
}

struct UniFiVPNServer: Codable, Identifiable {
    let id: String
    let name: String?
}

struct UniFiSite: Codable, Identifiable {
    let id: String
    let name: String?
    let internalReference: String?
}

struct UniFiGenericItem: Codable, Identifiable {
    let id: String?
    let name: String?
    let model: String?

    var displayName: String {
        name ?? model ?? id ?? "unknown"
    }
}
