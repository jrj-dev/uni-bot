import Foundation

final class UniFiQueryService {
    private let client: UniFiAPIClient
    private let siteResolver: SiteIDResolver
    private static let sanitizedQueries: Set<String> = ["events", "wlanconf", "networkconf"]
    private static let sensitiveKeyFragments = [
        "passphrase",
        "password",
        "token",
        "secret",
        "private_key",
        "privatekey",
        "ssh_key",
        "certificate",
        "cert",
        "fingerprint",
        "hash",
        "sha",
        "api_key",
        "apikey",
        "psk",
        "sae_psk",
        "auth_key",
        "encryption_key",
        "x_ssh_password",
        "x_iapp_key",
    ]

    private static let siteQueries: [String: String] = [
        "devices": "/proxy/network/integration/v1/sites/{site_id}/devices",
        "clients": "/proxy/network/integration/v1/sites/{site_id}/clients",
        "clients-all": "/proxy/network/integration/v1/sites/{site_id}/clients?includeInactive=true",
        "networks": "/proxy/network/integration/v1/sites/{site_id}/networks",
        "wifi-broadcasts": "/proxy/network/integration/v1/sites/{site_id}/wifi/broadcasts",
        "firewall-policies": "/proxy/network/integration/v1/sites/{site_id}/firewall/policies",
        "firewall-policies-ordering": "/proxy/network/integration/v1/sites/{site_id}/firewall/policies/ordering",
        "firewall-zones": "/proxy/network/integration/v1/sites/{site_id}/firewall/zones",
        "acl-rules": "/proxy/network/integration/v1/sites/{site_id}/acl-rules",
        "acl-rules-ordering": "/proxy/network/integration/v1/sites/{site_id}/acl-rules/ordering",
        "dns-policies": "/proxy/network/integration/v1/sites/{site_id}/dns/policies",
        "wan-profiles": "/proxy/network/integration/v1/sites/{site_id}/wans",
        "vpn-servers": "/proxy/network/integration/v1/sites/{site_id}/vpn/servers",
        "site-to-site-vpn": "/proxy/network/integration/v1/sites/{site_id}/vpn/site-to-site-tunnels",
        "radius-profiles": "/proxy/network/integration/v1/sites/{site_id}/radius/profiles",
        "hotspot-vouchers": "/proxy/network/integration/v1/sites/{site_id}/hotspot/vouchers",
    ]
    private static let legacySiteRefQueries: [String: String] = [
        "events": "/proxy/network/api/s/{site_ref}/stat/event",
        "wlanconf": "/proxy/network/api/s/{site_ref}/rest/wlanconf",
        "networkconf": "/proxy/network/api/s/{site_ref}/rest/networkconf",
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

    /// Runs a named UniFi query and returns the pretty-printed JSON response.
    func query(_ name: String, resourceID: String? = nil) async throws -> String {
        debugLog("Resolving query '\(name)'", category: "UniFiQuery")
        let path = try await resolvePath(name, resourceID: resourceID)
        let isResourceQuery = Self.resourceQueries.keys.contains(name)

        if isResourceQuery {
            let json = sanitizePayloadIfNeeded(try await client.getJSON(path: path), for: name)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        let items = sanitizeItemsIfNeeded(try await client.getAllPages(path: path), for: name)
        let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Runs a named UniFi query and extracts the returned row dictionaries.
    func queryItems(_ name: String) async throws -> [[String: Any]] {
        let path = try await resolvePath(name)
        return sanitizeItemsIfNeeded(try await client.getAllPages(path: path), for: name)
    }

    /// Maps a named query onto the concrete UniFi API path it should call.
    private func resolvePath(_ name: String, resourceID: String? = nil) async throws -> String {
        if let template = Self.globalQueries[name] {
            return template
        }
        if let template = Self.siteQueries[name] {
            let siteID = try await siteResolver.resolve(using: client)
            return template.replacingOccurrences(of: "{site_id}", with: siteID)
        }
        if let template = Self.legacySiteRefQueries[name] {
            let siteRef = try await siteResolver.resolveReference(using: client)
            return template.replacingOccurrences(of: "{site_ref}", with: siteRef)
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

    /// Redacts sensitive values from selected legacy/private query payloads.
    private func sanitizePayloadIfNeeded(_ payload: Any, for queryName: String) -> Any {
        guard Self.sanitizedQueries.contains(queryName) else { return payload }
        return sanitizeValue(payload)
    }

    /// Redacts sensitive values from selected legacy/private list payloads.
    private func sanitizeItemsIfNeeded(_ items: [[String: Any]], for queryName: String) -> [[String: Any]] {
        guard Self.sanitizedQueries.contains(queryName) else { return items }
        return items.map { sanitizeDictionary($0) }
    }

    private func sanitizeValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return sanitizeDictionary(dict)
        }
        if let array = value as? [Any] {
            return array.map { sanitizeValue($0) }
        }
        return value
    }

    private func sanitizeDictionary(_ dict: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in dict {
            if Self.isSensitiveKey(key) {
                sanitized[key] = "<redacted>"
            } else {
                sanitized[key] = sanitizeValue(value)
            }
        }
        return sanitized
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}

private actor SiteIDResolver {
    private let configuredSiteID: String?
    private var resolvedSiteID: String?
    private var resolvedSiteReference: String?
    private var inFlightResolution: Task<String, Error>?
    private var inFlightReferenceResolution: Task<String, Error>?

    init(configuredSiteID: String?) {
        if let configuredSiteID, !configuredSiteID.isEmpty {
            self.configuredSiteID = configuredSiteID
        } else {
            self.configuredSiteID = nil
        }
    }

    /// Resolves the active site identifier, using the default site when needed.
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

    /// Resolves the legacy site reference used by `/api/s/{site_ref}/...` paths.
    func resolveReference(using client: UniFiAPIClient) async throws -> String {
        if let resolvedSiteReference {
            debugLog("Using cached resolved site reference", category: "UniFiQuery")
            return resolvedSiteReference
        }
        if let inFlightReferenceResolution {
            return try await inFlightReferenceResolution.value
        }

        let task = Task<String, Error> {
            debugLog("Resolving site reference from /sites", category: "UniFiQuery")
            return try await Self.fetchDefaultSiteReference(
                configuredSiteID: configuredSiteID,
                using: client
            )
        }
        inFlightReferenceResolution = task
        defer { inFlightReferenceResolution = nil }

        let siteReference = try await task.value
        resolvedSiteReference = siteReference
        return siteReference
    }

    /// Fetches the default UniFi site ID from the sites endpoint.
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

    /// Fetches the site reference (`default`, etc.) used by legacy UniFi API paths.
    private static func fetchDefaultSiteReference(
        configuredSiteID: String?,
        using client: UniFiAPIClient
    ) async throws -> String {
        let payload = try await client.getJSON(path: "/proxy/network/integration/v1/sites")
        guard let dict = payload as? [String: Any], let sites = dict["data"] as? [[String: Any]] else {
            throw UniFiAPIError.siteResolutionFailed("unexpected /sites response format")
        }
        guard !sites.isEmpty else {
            throw UniFiAPIError.siteResolutionFailed("no sites were returned by the controller")
        }

        if let configuredSiteID,
           let configuredReference = sites.first(where: { ($0["id"] as? String) == configuredSiteID })?["internalReference"] as? String,
           !configuredReference.isEmpty
        {
            debugLog("Resolved site reference using configured site ID", category: "UniFiQuery")
            return configuredReference
        }
        if let defaultReference = sites.first(where: { ($0["internalReference"] as? String) == "default" })?["internalReference"] as? String,
           !defaultReference.isEmpty
        {
            debugLog("Resolved site reference using internalReference=default", category: "UniFiQuery")
            return defaultReference
        }
        if let firstReference = sites.first?["internalReference"] as? String, !firstReference.isEmpty {
            debugLog("Resolved site reference using first available site", category: "UniFiQuery")
            return firstReference
        }

        throw UniFiAPIError.siteResolutionFailed("site list did not include a valid site reference")
    }
}

#if DEBUG
extension UniFiQueryService {
    func _testOnlySanitizePayload(_ payload: Any, for queryName: String) async -> [String: Any] {
        sanitizePayloadIfNeeded(payload, for: queryName) as? [String: Any] ?? [:]
    }
}
#endif
