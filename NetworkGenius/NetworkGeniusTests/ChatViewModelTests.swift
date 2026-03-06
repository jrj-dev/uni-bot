import XCTest
@testable import NetworkGenius

final class ChatViewModelTests: XCTestCase {
    @MainActor
    func testInitialState() {
        let vm = ChatViewModel()
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.currentToolName)
    }
}
