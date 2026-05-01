import XCTest
@testable import MetamorphiaRemoteKit

final class CommandRoundTripTests: XCTestCase {
    func test_parameterlessCommandsRoundTripThroughKind() {
        let cases: [Command] = [.sleepMac, .lockMac, .playMusic, .pauseMusic, .nextTrack, .previousTrack]
        for command in cases {
            let decoded = Command.decode(kind: command.kind, payload: command.payload)
            XCTAssertEqual(decoded, command, "round-trip failed for \(command.kind)")
        }
    }

    func test_setKeepAwakeRoundTripsWithPayload() {
        for value in [true, false] {
            let command = Command.setKeepAwake(value)
            let decoded = Command.decode(kind: command.kind, payload: command.payload)
            XCTAssertEqual(decoded, command)
        }
    }

    func test_unknownKindReturnsNil() {
        XCTAssertNil(Command.decode(kind: "format_disk", payload: nil))
    }
}
