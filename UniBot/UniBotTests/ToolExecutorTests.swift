import XCTest
@testable import UniBot

final class ToolExecutorTests: XCTestCase {
    func testToolCatalogIncludesExpectedRecentTools() {
        let names = Set(ToolCatalog.all.map(\.name))

        XCTAssertTrue(names.contains("list_clients_with_app_blocks"))
        XCTAssertTrue(names.contains("summarize_policy_engine_objects"))
        XCTAssertTrue(names.contains("compare_policy_engine_paths"))
    }

    func testBasicModeHidesAdvancedTools() {
        let basicTools = ToolCatalog.availableTools(for: .basic)
        let basicNames = Set(basicTools.map(\.name))

        XCTAssertFalse(basicNames.contains("query_unifi_logs"))
        XCTAssertFalse(basicNames.contains("ssh_collect_unifi_logs"))
        XCTAssertFalse(basicNames.contains("network_traceroute"))
        XCTAssertFalse(basicNames.contains("list_clients_with_app_blocks"))
        XCTAssertFalse(basicNames.contains("summarize_policy_engine_objects"))
        XCTAssertTrue(basicNames.contains("search_unifi_docs"))
        XCTAssertTrue(basicNames.contains("resolve_client_for_app_block"))
        XCTAssertTrue(basicNames.contains("resolve_dpi_application"))
        XCTAssertTrue(basicNames.contains("resolve_dpi_category"))
        XCTAssertTrue(basicNames.contains("plan_client_app_block"))
        XCTAssertTrue(basicNames.contains("apply_client_app_block"))
        XCTAssertTrue(basicNames.contains("remove_client_app_block"))
        XCTAssertTrue(basicNames.contains("list_client_app_block"))
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
                allowClientModifications: true,
                allowAppBlocks: true,
                isCurrentlyConnected: true
            )
        ]

        let merged = ClientModificationApproval.merge(currentClients: [], existing: existing)

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].allowClientModifications)
        XCTAssertTrue(merged[0].allowAppBlocks)
        XCTAssertFalse(merged[0].isCurrentlyConnected)
    }

    func testFormatClientsWithAppBlocksDedupesByMACAndCountsTargets() {
        let output = _testOnlyFormatClientsWithAppBlocks(
            rules: [
                [
                    "type": "DEVICE",
                    "target_type": "APP_ID",
                    "client_macs": ["AA:BB:CC:DD:EE:FF"],
                    "app_ids": ["youtube", "netflix"],
                ],
                [
                    "type": "DEVICE",
                    "target_type": "APP_CATEGORY",
                    "client_macs": ["aa:bb:cc:dd:ee:ff"],
                    "app_category_ids": ["streaming"],
                ],
            ],
            clients: [
                [
                    "name": "Living Room TV",
                    "ip": "192.168.1.50",
                    "mac": "AA:BB:CC:DD:EE:FF",
                ]
            ],
            siteRef: "default",
            limit: 20
        )

        XCTAssertTrue(output.contains("- blocked_client_count: 1"))
        XCTAssertTrue(output.contains("- rules_considered: 2"))
        XCTAssertTrue(output.contains("1. name=Living Room TV, ip=192.168.1.50, mac=aa:bb:cc:dd:ee:ff, rules=2, app_ids=2, category_ids=1"))
    }

    func testFormatClientsWithAppBlocksHandlesUnknownClientAndLimit() {
        let output = _testOnlyFormatClientsWithAppBlocks(
            rules: [
                [
                    "type": "DEVICE",
                    "target_type": "APP_ID",
                    "client_macs": ["11:22:33:44:55:66"],
                    "app_ids": ["youtube"],
                ],
                [
                    "type": "DEVICE",
                    "target_type": "APP_ID",
                    "client_macs": ["AA:BB:CC:DD:EE:FF"],
                    "app_ids": ["discord"],
                ],
            ],
            clients: [
                [
                    "name": "Known Client",
                    "ip": "192.168.1.22",
                    "mac": "AA:BB:CC:DD:EE:FF",
                ]
            ],
            siteRef: "default",
            limit: 1
        )

        XCTAssertTrue(output.contains("- blocked_client_count: 2"))
        XCTAssertTrue(output.contains("- showing: 1"))
        XCTAssertEqual(output.components(separatedBy: "\n").filter { $0.hasPrefix("1. ") || $0.hasPrefix("2. ") }.count, 1)
        XCTAssertTrue(output.contains("Unknown client") || output.contains("Known Client"))
    }
}
