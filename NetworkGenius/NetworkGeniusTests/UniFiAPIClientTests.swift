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
}
