import XCTest
@testable import MetamorphiaAgentKit

final class ProtocolShapeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(MetamorphiaAgentKit.version, "0.1.0")
    }

    func testNullProgressSinkAcceptsEvents() {
        let sink: AgentProgressSink = NullProgressSink()
        sink.publish(AgentProgressEvent(kind: .started, message: "test"))
        // If we got here without crashing, the sink is wired correctly.
    }

    func testNullSystemContextProviderReturnsEmptySnapshot() async {
        let provider: SystemContextProvider = NullSystemContextProvider()
        let snapshot = await provider.currentContext()
        XCTAssertNil(snapshot.frontmostApp)
        XCTAssertNil(snapshot.batteryLevel)
        XCTAssertFalse(snapshot.systemPromptAddendum.isEmpty) // still contains the time line
    }

    func testSystemPromptAddendumIncludesPopulatedFields() {
        let snapshot = SystemContextSnapshot(
            frontmostApp: "Xcode",
            isDarkMode: true,
            batteryLevel: 87
        )
        let addendum = snapshot.systemPromptAddendum
        XCTAssertTrue(addendum.contains("Xcode"))
        XCTAssertTrue(addendum.contains("dark"))
        XCTAssertTrue(addendum.contains("87%"))
    }
}
