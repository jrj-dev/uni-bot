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
    private enum CodingKeys: String, CodingKey {
        case approvalKey
        case clientID
        case name
        case hostname
        case mac
        case ip
        case isApproved
        case allowClientModifications
        case allowAppBlocks
        case isCurrentlyConnected
        case isLegacyHistoryEntry
    }

    let approvalKey: String
    var clientID: String
    var name: String
    var hostname: String
    var mac: String
    var ip: String
    var allowClientModifications: Bool
    var allowAppBlocks: Bool
    var isCurrentlyConnected: Bool
    var isLegacyHistoryEntry: Bool

    var id: String { approvalKey }

    init(
        approvalKey: String,
        clientID: String,
        name: String,
        hostname: String,
        mac: String,
        ip: String,
        allowClientModifications: Bool,
        allowAppBlocks: Bool,
        isCurrentlyConnected: Bool,
        isLegacyHistoryEntry: Bool = false
    ) {
        self.approvalKey = approvalKey
        self.clientID = clientID
        self.name = name
        self.hostname = hostname
        self.mac = mac
        self.ip = ip
        self.allowClientModifications = allowClientModifications
        self.allowAppBlocks = allowAppBlocks
        self.isCurrentlyConnected = isCurrentlyConnected
        self.isLegacyHistoryEntry = isLegacyHistoryEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvalKey = try container.decode(String.self, forKey: .approvalKey)
        clientID = try container.decode(String.self, forKey: .clientID)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        mac = try container.decode(String.self, forKey: .mac)
        ip = try container.decode(String.self, forKey: .ip)
        let legacyApproved = try container.decodeIfPresent(Bool.self, forKey: .isApproved) ?? false
        let storedModificationApproval = try container.decodeIfPresent(Bool.self, forKey: .allowClientModifications)
        let storedAppBlockApproval = try container.decodeIfPresent(Bool.self, forKey: .allowAppBlocks)
        let unifiedApproval = storedModificationApproval ?? storedAppBlockApproval ?? legacyApproved
        allowClientModifications = unifiedApproval
        allowAppBlocks = unifiedApproval
        isCurrentlyConnected = try container.decode(Bool.self, forKey: .isCurrentlyConnected)
        isLegacyHistoryEntry = try container.decodeIfPresent(Bool.self, forKey: .isLegacyHistoryEntry) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(approvalKey, forKey: .approvalKey)
        try container.encode(clientID, forKey: .clientID)
        try container.encode(name, forKey: .name)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(mac, forKey: .mac)
        try container.encode(ip, forKey: .ip)
        try container.encode(allowClientModifications, forKey: .allowClientModifications)
        try container.encode(isCurrentlyConnected, forKey: .isCurrentlyConnected)
        try container.encode(isLegacyHistoryEntry, forKey: .isLegacyHistoryEntry)
    }

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
                allowClientModifications: previous?.allowClientModifications ?? false,
                allowAppBlocks: previous?.allowClientModifications ?? false,
                isCurrentlyConnected: true,
                isLegacyHistoryEntry: false
            )
        }

        for entry in existing where mergedByKey[entry.approvalKey] == nil {
            var staleEntry = entry
            staleEntry.isCurrentlyConnected = false
            mergedByKey[entry.approvalKey] = staleEntry
        }

        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.allowClientModifications != rhs.allowClientModifications {
                return lhs.allowClientModifications && !rhs.allowClientModifications
            }
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func mergeLegacyAppBlockSelectors(
        existing: [ClientModificationApproval],
        selectors: [String],
        nameMap: [String: String]
    ) -> [ClientModificationApproval] {
        guard !selectors.isEmpty else { return existing }

        var mergedByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.approvalKey, $0) })
        for selector in selectors {
            let normalized = normalizeIdentifier(selector)
            guard !normalized.isEmpty else { continue }
            let existingEntry = mergedByKey[normalized]
            let displayName = (nameMap[selector] ?? nameMap[normalized] ?? existingEntry?.name ?? selector)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mergedByKey[normalized] = ClientModificationApproval(
                approvalKey: normalized,
                clientID: existingEntry?.clientID ?? normalized,
                name: displayName,
                hostname: existingEntry?.hostname ?? "",
                mac: existingEntry?.mac ?? selector,
                ip: existingEntry?.ip ?? "",
                allowClientModifications: true,
                allowAppBlocks: true,
                isCurrentlyConnected: existingEntry?.isCurrentlyConnected ?? false,
                isLegacyHistoryEntry: existingEntry?.isLegacyHistoryEntry ?? false
            )
        }
        return mergedByKey.values.sorted { lhs, rhs in
            if lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) != .orderedSame {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.approvalKey < rhs.approvalKey
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
