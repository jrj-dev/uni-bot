import XCTest
@testable import NetworkGenius

final class ToolExecutorTests: XCTestCase {
    func testToolCatalogHas18Tools() {
        XCTAssertEqual(ToolCatalog.all.count, 18)
    }

    func testClaudeToolSchemasHaveRequiredFields() {
        let schemas = ToolCatalog.claudeToolSchemas()
        for schema in schemas {
            XCTAssertNotNil(schema["name"] as? String)
            XCTAssertNotNil(schema["description"] as? String)
            XCTAssertNotNil(schema["input_schema"] as? [String: Any])
        }
    }

    func testOpenAIToolSchemasHaveRequiredFields() {
        let schemas = ToolCatalog.openAIToolSchemas()
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
}
