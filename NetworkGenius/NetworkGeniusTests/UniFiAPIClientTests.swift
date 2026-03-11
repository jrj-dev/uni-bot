import XCTest
@testable import NetworkGenius

final class UniFiAPIClientTests: XCTestCase {
    func testClientInitTrimsTrailingSlash() {
        let client = UniFiAPIClient(baseURL: "https://192.168.1.1/", allowSelfSigned: true)
        XCTAssertEqual(client.baseURL, "https://192.168.1.1")
    }

    func testClientInitPreservesCleanURL() {
        let client = UniFiAPIClient(baseURL: "https://192.168.1.1", allowSelfSigned: false)
        XCTAssertEqual(client.baseURL, "https://192.168.1.1")
        XCTAssertFalse(client.allowSelfSigned)
    }

    func testLegacyQuerySanitizerRedactsSensitiveFields() async throws {
        let client = UniFiAPIClient(baseURL: "https://192.168.1.1", allowSelfSigned: true)
        let service = UniFiQueryService(client: client, siteID: nil)
        let payload: [String: Any] = [
            "data": [
                [
                    "name": "JHOME",
                    "x_passphrase": "!Nintendo64!",
                    "nested": [
                        "token": "abc123",
                        "private_preshared_keys": [
                            ["passphrase": "guest-pass"]
                        ],
                    ],
                ]
            ]
        ]

        let sanitized = await service._testOnlySanitizePayload(payload, for: "wlanconf")

        let rows = try XCTUnwrap(sanitized["data"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["x_passphrase"] as? String, "<redacted>")
        let nested = try XCTUnwrap(rows[0]["nested"] as? [String: Any])
        XCTAssertEqual(nested["token"] as? String, "<redacted>")
        let ppsks = try XCTUnwrap(nested["private_preshared_keys"] as? [[String: Any]])
        XCTAssertEqual(ppsks[0]["passphrase"] as? String, "<redacted>")
    }
}
