import Foundation

final class UniFiQueryService {
    private let client: UniFiAPIClient
    private let siteResolver: SiteIDResolver

    private static let siteQueries: [String: String] = [
        "devices": "/proxy/network/integration/v1/sites/{site_id}/devices",
        "clients": "/proxy/network/integration/v1/sites/{site_id}/clients",
        "clients-all": "/proxy/network/integration/v1/sites/{site_id}/clients?includeInactive=true",
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
        "dpi-applications": "/proxy/network/integration/v1/dpi/applications",
        "dpi-categories": "/proxy/network/integration/v1/dpi/categories",
    ]

    private static let resourceQueries: [String: (idParam: String, template: String)] = [
        "device": ("device_id", "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}"),
        "device-stats": ("device_id", "/proxy/network/integration/v1/sites/{site_id}/devices/{device_id}/statistics/latest"),
        "client": ("client_id", "/proxy/network/integration/v1/sites/{site_id}/clients/{client_id}"),
    ]

    init(client: UniFiAPIClient, siteID: String?) {
        self.client = client
        let cleanedSiteID = siteID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.siteResolver = SiteIDResolver(configuredSiteID: cleanedSiteID)
    }

    func query(_ name: String, resourceID: String? = nil) async throws -> String {
        debugLog("Resolving query '\(name)'", category: "UniFiQuery")
        let path = try await resolvePath(name, resourceID: resourceID)
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
        let path = try await resolvePath(name)
        return try await client.getAllPages(path: path)
    }

    private func resolvePath(_ name: String, resourceID: String? = nil) async throws -> String {
        if let template = Self.globalQueries[name] {
            return template
        }
        if let template = Self.siteQueries[name] {
            let siteID = try await siteResolver.resolve(using: client)
            return template.replacingOccurrences(of: "{site_id}", with: siteID)
        }
        if let resource = Self.resourceQueries[name] {
            guard let id = resourceID else {
                throw UniFiAPIError.invalidURL("Resource query '\(name)' requires \(resource.idParam)")
            }
            let siteID = try await siteResolver.resolve(using: client)
            return resource.template
                .replacingOccurrences(of: "{site_id}", with: siteID)
                .replacingOccurrences(of: "{\(resource.idParam)}", with: id)
        }
        throw UniFiAPIError.invalidURL("Unknown query: \(name)")
    }
}

private actor SiteIDResolver {
    private let configuredSiteID: String?
    private var resolvedSiteID: String?
    private var inFlightResolution: Task<String, Error>?

    init(configuredSiteID: String?) {
        if let configuredSiteID, !configuredSiteID.isEmpty {
            self.configuredSiteID = configuredSiteID
        } else {
            self.configuredSiteID = nil
        }
    }

    func resolve(using client: UniFiAPIClient) async throws -> String {
        if let configuredSiteID {
            debugLog("Using configured site ID", category: "UniFiQuery")
            return configuredSiteID
        }
        if let resolvedSiteID {
            debugLog("Using cached resolved site ID", category: "UniFiQuery")
            return resolvedSiteID
        }
        if let inFlightResolution {
            return try await inFlightResolution.value
        }

        let task = Task<String, Error> {
            debugLog("Resolving site ID from /sites", category: "UniFiQuery")
            return try await Self.fetchDefaultSiteID(using: client)
        }
        inFlightResolution = task
        defer { inFlightResolution = nil }

        let siteID = try await task.value
        resolvedSiteID = siteID
        return siteID
    }

    private static func fetchDefaultSiteID(using client: UniFiAPIClient) async throws -> String {
        let payload = try await client.getJSON(path: "/proxy/network/integration/v1/sites")
        guard let dict = payload as? [String: Any], let sites = dict["data"] as? [[String: Any]] else {
            throw UniFiAPIError.siteResolutionFailed("unexpected /sites response format")
        }
        guard !sites.isEmpty else {
            throw UniFiAPIError.siteResolutionFailed("no sites were returned by the controller")
        }

        if let defaultSiteID = sites.first(where: { ($0["internalReference"] as? String) == "default" })?["id"] as? String,
           !defaultSiteID.isEmpty
        {
            debugLog("Resolved site ID using internalReference=default", category: "UniFiQuery")
            return defaultSiteID
        }
        if let firstSiteID = sites.first?["id"] as? String, !firstSiteID.isEmpty {
            debugLog("Resolved site ID using first available site", category: "UniFiQuery")
            return firstSiteID
        }

        throw UniFiAPIError.siteResolutionFailed("site list did not include a valid site ID")
    }
}
