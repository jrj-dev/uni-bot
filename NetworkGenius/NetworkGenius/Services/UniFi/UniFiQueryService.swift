import Foundation

final class UniFiQueryService {
    private let client: UniFiAPIClient
    private let siteID: String

    private static let siteQueries: [String: String] = [
        "devices": "/proxy/network/integration/v1/sites/{site_id}/devices",
        "clients": "/proxy/network/integration/v1/sites/{site_id}/clients",
        "networks": "/proxy/network/integration/v1/sites/{site_id}/networks",
        "wifi-broadcasts": "/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts",
        "firewall-policies": "/proxy/network/integration/v1/sites/{site_id}/firewall/policies",
        "firewall-zones": "/proxy/network/integration/v1/sites/{site_id}/firewall/zones",
        "acl-rules": "/proxy/network/integration/v1/sites/{site_id}/acl-rules",
        "dns-policies": "/proxy/network/integration/v1/sites/{site_id}/dns/policies",
        "vpn-servers": "/proxy/network/integration/v1/sites/{site_id}/vpn/servers",
        "site-to-site-vpn": "/proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels",
        "radius-profiles": "/proxy/network/integration/v1/sites/{site_id}/radius/profiles",
        "hotspot-vouchers": "/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers",
    ]

    private static let globalQueries: [String: String] = [
        "sites": "/proxy/network/integration/v1/sites",
        "pending-devices": "/proxy/network/integration/v1/pending-devices",
    ]

    private static let resourceQueries: [String: (idParam: String, template: String)] = [
        "device": ("device_id", "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}"),
        "device-stats": ("device_id", "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}/statistics/latest"),
        "client": ("client_id", "/proxy/network/integration/v1/sites/{site_id}/clients/{client_id}"),
    ]

    init(client: UniFiAPIClient, siteID: String) {
        self.client = client
        self.siteID = siteID
    }

    func query(_ name: String, resourceID: String? = nil) async throws -> String {
        let path = try resolvePath(name, resourceID: resourceID)
        let isResourceQuery = Self.resourceQueries.keys.contains(name)

        if isResourceQuery {
            let json = try await client.getJSON(path: path)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        let items = try await client.getAllPages(path: path)
        let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func queryItems(_ name: String) async throws -> [[String: Any]] {
        let path = try resolvePath(name)
        return try await client.getAllPages(path: path)
    }

    private func resolvePath(_ name: String, resourceID: String? = nil) throws -> String {
        if let template = Self.globalQueries[name] {
            return template
        }
        if let template = Self.siteQueries[name] {
            return template.replacingOccurrences(of: "{site_id}", with: siteID)
        }
        if let resource = Self.resourceQueries[name] {
            guard let id = resourceID else {
                throw UniFiAPIError.invalidURL("Resource query '\(name)' requires \(resource.idParam)")
            }
            return resource.template
                .replacingOccurrences(of: "{site_id}", with: siteID)
                .replacingOccurrences(of: "{\(resource.idParam)}", with: id)
        }
        throw UniFiAPIError.invalidURL("Unknown query: \(name)")
    }
}
