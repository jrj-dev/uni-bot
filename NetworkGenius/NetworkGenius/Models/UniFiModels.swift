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

