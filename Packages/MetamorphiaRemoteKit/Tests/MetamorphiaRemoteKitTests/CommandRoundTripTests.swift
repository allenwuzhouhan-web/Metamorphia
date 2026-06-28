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

    func test_askAgentRoundTripsWithPromptAndSessionID() {
        let prompt = "What is on my clipboard?"
        let sessionID = "phone-session-42"
        let command = Command.askAgent(prompt: prompt, sessionID: sessionID)
        let decoded = Command.decode(kind: command.kind, payload: command.payload)
        XCTAssertEqual(decoded, command)
        if case .askAgent(let decodedPrompt, let decodedSessionID) = decoded {
            XCTAssertEqual(decodedPrompt, prompt)
            XCTAssertEqual(decodedSessionID, sessionID)
        } else {
            XCTFail("decoded command was not .askAgent")
        }
    }

    func test_unknownKindReturnsNil() {
        XCTAssertNil(Command.decode(kind: "format_disk", payload: nil))
    }
}
