import XCTest
@testable import UniBot

final class ChatViewModelTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let vm = ChatViewModel()
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.currentToolName)
    }

    @MainActor
    func testOversizedRequestMapsToUserFacingFallback() {
        let vm = ChatViewModel()

        let message = vm._testOnlyUserFacingChatErrorMessage(
            for: LLMError.httpError(400, "context_length_exceeded: request too large")
        )

        XCTAssertTrue(message.contains("request grew too large"))
        XCTAssertTrue(message.contains("rephrase more narrowly"))
    }

    @MainActor
    func testCappedToolResultTruncatesLargePayloads() {
        let vm = ChatViewModel()
        let oversized = String(repeating: "A", count: 8_500)

        let result = vm._testOnlyCappedToolResult(oversized, toolName: "list_clients")

        XCTAssertTrue(result.contains("TOOL_RESULT_TRUNCATED: list_clients"))
        XCTAssertLessThan(result.count, oversized.count)
        XCTAssertTrue(result.contains("first 8000 characters"))
    }

    @MainActor
    func testCappedToolResultLeavesSmallPayloadUntouched() {
        let vm = ChatViewModel()
        let small = "short payload"

        XCTAssertEqual(vm._testOnlyCappedToolResult(small, toolName: "list_clients"), small)
    }
}
