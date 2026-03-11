import XCTest
@testable import NetworkGenius

final class ToolExecutorTests: XCTestCase {
    func testToolCatalogHas47Tools() {
        XCTAssertEqual(ToolCatalog.all.count, 47)
    }

    func testBasicModeHidesAdvancedTools() {
        let basicTools = ToolCatalog.availableTools(for: .basic)
        let basicNames = Set(basicTools.map(\.name))

        XCTAssertFalse(basicNames.contains("query_unifi_logs"))
        XCTAssertFalse(basicNames.contains("ssh_collect_unifi_logs"))
        XCTAssertFalse(basicNames.contains("network_traceroute"))
        XCTAssertTrue(basicNames.contains("search_unifi_docs"))
        XCTAssertTrue(basicNames.contains("plan_client_app_block"))
    }

    func testClaudeToolSchemasHaveRequiredFields() {
        let schemas = ToolCatalog.claudeToolSchemas(for: .advanced)
        for schema in schemas {
            XCTAssertNotNil(schema["name"] as? String)
            XCTAssertNotNil(schema["description"] as? String)
            XCTAssertNotNil(schema["input_schema"] as? [String: Any])
        }
    }

    func testOpenAIToolSchemasHaveRequiredFields() {
        let schemas = ToolCatalog.openAIToolSchemas(for: .advanced)
        for schema in schemas {
            XCTAssertEqual(schema["type"] as? String, "function")
            let function = schema["function"] as? [String: Any]
            XCTAssertNotNil(function?["name"] as? String)
            XCTAssertNotNil(function?["description"] as? String)
            XCTAssertNotNil(function?["parameters"] as? [String: Any])
        }
    }

    func testToolNamesAreUnique() {
        let names = ToolCatalog.all.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testAdvancedModeIncludesAllTools() {
        XCTAssertEqual(
            Set(ToolCatalog.availableTools(for: .advanced).map(\.name)),
            Set(ToolCatalog.all.map(\.name))
        )
    }

    func testClientModificationApprovalUsesMACAsStableKey() {
        let client = UniFiClient(
            id: "client-1",
            name: "Office MacBook",
            hostname: "mbp.local",
            mac: "AA:BB:CC:DD:EE:FF",
            ip: "192.168.1.25",
            type: "WIRELESS",
            uplinkDeviceId: "ap-1",
            access: nil
        )

        XCTAssertEqual(ClientModificationApproval.approvalKey(for: client), "aa:bb:cc:dd:ee:ff")
    }

    func testClientModificationApprovalMergePreservesApprovalsForOfflineClients() {
        let existing = [
            ClientModificationApproval(
                approvalKey: "aa:bb:cc:dd:ee:ff",
                clientID: "old-id",
                name: "Office MacBook",
                hostname: "mbp.local",
                mac: "AA:BB:CC:DD:EE:FF",
                ip: "192.168.1.25",
                isApproved: true,
                isCurrentlyConnected: true
            )
        ]

        let merged = ClientModificationApproval.merge(currentClients: [], existing: existing)

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isApproved)
        XCTAssertFalse(merged[0].isCurrentlyConnected)
    }
}
