import XCTest
import CoreGraphics
import AppKit
@testable import MetamorphiaPerception

/// Rank 9 — Gesture & Event Synthesis.
///
/// These tests exercise the pure-data paths of `GestureExecutor`:
/// - `KeyMap` keycode coverage (a-z, A-Z, 0-9, punctuation, named keys, F-keys)
/// - `KeyModifiers.cgEventFlags` bit-combining
/// - `GestureExecutor.clamp(point:)` bounds-enforcement
/// - `GestureExecutor.flipY(_:screen:)` Cartesian/top-left involution
/// - `GestureExecutor.planTyping(text:)` ASCII + unicode mixed input
///
/// Event-posting tests are deliberately avoided — actually firing clicks
/// during `swift test` would disturb the user's session and is unreliable
/// across CI environments. The above surface area is enough to guarantee
/// correctness of the parts that could silently regress without a test.
final class GestureExecutorTests: XCTestCase {

    // MARK: - KeyMap — letters a-z

    func testKeyMap_lowercaseLetters_mapToExpectedCodes() {
        // Spot-checks that match Apple's Carbon Events.h keycode constants.
        XCTAssertEqual(KeyMap.keyCode(for: "a"), 0x00)
        XCTAssertEqual(KeyMap.keyCode(for: "s"), 0x01)
        XCTAssertEqual(KeyMap.keyCode(for: "d"), 0x02)
        XCTAssertEqual(KeyMap.keyCode(for: "f"), 0x03)
        XCTAssertEqual(KeyMap.keyCode(for: "h"), 0x04)
        XCTAssertEqual(KeyMap.keyCode(for: "g"), 0x05)
        XCTAssertEqual(KeyMap.keyCode(for: "z"), 0x06)
        XCTAssertEqual(KeyMap.keyCode(for: "q"), 0x0C)
        XCTAssertEqual(KeyMap.keyCode(for: "w"), 0x0D)
        XCTAssertEqual(KeyMap.keyCode(for: "e"), 0x0E)
        XCTAssertEqual(KeyMap.keyCode(for: "r"), 0x0F)
        XCTAssertEqual(KeyMap.keyCode(for: "m"), 0x2E)
    }

    // MARK: - KeyMap — uppercase (shift-produced) letters

    func testKeyMap_uppercaseLetters_reuseLowercaseCodes() {
        // Uppercase is produced by Shift + same physical keycode.
        XCTAssertEqual(KeyMap.keyCode(for: "A"), 0x00)
        XCTAssertEqual(KeyMap.keyCode(for: "Z"), 0x06)
        XCTAssertEqual(KeyMap.keyCode(for: "M"), 0x2E)
    }

    // MARK: - KeyMap — digits

    func testKeyMap_digits_mapToTopRowKeycodes() {
        XCTAssertEqual(KeyMap.keyCode(for: "1"), 0x12)
        XCTAssertEqual(KeyMap.keyCode(for: "2"), 0x13)
        XCTAssertEqual(KeyMap.keyCode(for: "3"), 0x14)
        XCTAssertEqual(KeyMap.keyCode(for: "4"), 0x15)
        XCTAssertEqual(KeyMap.keyCode(for: "0"), 0x1D)
    }

    // MARK: - KeyMap — punctuation (unshifted)

    func testKeyMap_commonPunctuation() {
        XCTAssertEqual(KeyMap.keyCode(for: ","), 0x2B)
        XCTAssertEqual(KeyMap.keyCode(for: "."), 0x2F)
        XCTAssertEqual(KeyMap.keyCode(for: "/"), 0x2C)
        XCTAssertEqual(KeyMap.keyCode(for: ";"), 0x29)
        XCTAssertEqual(KeyMap.keyCode(for: "'"), 0x27)
        XCTAssertEqual(KeyMap.keyCode(for: "["), 0x21)
        XCTAssertEqual(KeyMap.keyCode(for: "]"), 0x1E)
        XCTAssertEqual(KeyMap.keyCode(for: "-"), 0x1B)
        XCTAssertEqual(KeyMap.keyCode(for: "="), 0x18)
    }

    // MARK: - KeyMap — whitespace / control characters as chars

    func testKeyMap_whitespaceCharacters() {
        XCTAssertEqual(KeyMap.keyCode(for: " "), 0x31)
        XCTAssertEqual(KeyMap.keyCode(for: "\t"), 0x30)
        XCTAssertEqual(KeyMap.keyCode(for: "\n"), 0x24)
    }

    // MARK: - Named keys via GestureExecutor.resolveKeyCode

    func testResolveKeyCode_namedKeys_matchExpectedCodes() throws {
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.enter),  0x24)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.escape), 0x35)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.tab),    0x30)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.space),  0x31)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.delete), 0x33)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.forwardDelete), 0x75)
    }

    func testResolveKeyCode_arrowKeys() throws {
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.up),    0x7E)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.down),  0x7D)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.left),  0x7B)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.right), 0x7C)
    }

    func testResolveKeyCode_pageAndHomeEndKeys() throws {
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.home),     0x73)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.end),      0x77)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.pageUp),   0x74)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.pageDown), 0x79)
    }

    func testResolveKeyCode_functionKeys_f1ThroughF12() throws {
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f1),  0x7A)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f2),  0x78)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f3),  0x63)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f4),  0x76)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f5),  0x60)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f6),  0x61)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f7),  0x62)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f8),  0x64)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f9),  0x65)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f10), 0x6D)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f11), 0x67)
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.f12), 0x6F)
    }

    func testResolveKeyCode_rawKeyCodePassesThrough() throws {
        XCTAssertEqual(try GestureExecutor.resolveKeyCode(.keyCode(0x42)), 0x42)
    }

    func testResolveKeyCode_unknownCharacter_throwsInvalidKey() {
        // Emoji — not in the ASCII keycode tables.
        XCTAssertThrowsError(try GestureExecutor.resolveKeyCode(.character("🎉"))) { error in
            guard case GestureError.invalidKey = error else {
                XCTFail("Expected .invalidKey, got \(error)")
                return
            }
        }
    }

    // MARK: - KeyModifiers.cgEventFlags

    func testCgEventFlags_singleCommand() {
        let mods: KeyModifiers = .command
        XCTAssertTrue(mods.cgEventFlags.contains(.maskCommand))
        XCTAssertFalse(mods.cgEventFlags.contains(.maskShift))
    }

    func testCgEventFlags_singleShift() {
        let mods: KeyModifiers = .shift
        XCTAssertTrue(mods.cgEventFlags.contains(.maskShift))
        XCTAssertFalse(mods.cgEventFlags.contains(.maskCommand))
    }

    func testCgEventFlags_singleOption() {
        let mods: KeyModifiers = .option
        XCTAssertTrue(mods.cgEventFlags.contains(.maskAlternate))
    }

    func testCgEventFlags_singleControl() {
        let mods: KeyModifiers = .control
        XCTAssertTrue(mods.cgEventFlags.contains(.maskControl))
    }

    func testCgEventFlags_capsLockAndFunction() {
        let caps: KeyModifiers = .capsLock
        XCTAssertTrue(caps.cgEventFlags.contains(.maskAlphaShift))

        let fn: KeyModifiers = .function
        XCTAssertTrue(fn.cgEventFlags.contains(.maskSecondaryFn))
    }

    func testCgEventFlags_combination_cmdShift() {
        let mods: KeyModifiers = [.command, .shift]
        XCTAssertTrue(mods.cgEventFlags.contains(.maskCommand))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskShift))
        XCTAssertFalse(mods.cgEventFlags.contains(.maskControl))
    }

    func testCgEventFlags_combination_allSix() {
        let mods: KeyModifiers = [.command, .shift, .option, .control, .capsLock, .function]
        XCTAssertTrue(mods.cgEventFlags.contains(.maskCommand))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskShift))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskAlternate))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskControl))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskAlphaShift))
        XCTAssertTrue(mods.cgEventFlags.contains(.maskSecondaryFn))
    }

    func testCgEventFlags_emptyModifiers_isEmpty() {
        let mods: KeyModifiers = []
        XCTAssertTrue(mods.cgEventFlags.isEmpty)
    }

    // MARK: - Coordinate Clamping

    func testClamp_inBoundsPointPassesThrough() throws {
        // Any real display has origin at (0,0) so a point at (10,10) is in bounds.
        let point = CGPoint(x: 10, y: 10)
        let clamped = try GestureExecutor.clamp(point: point)
        XCTAssertEqual(clamped.x, 10, accuracy: 1)
        XCTAssertEqual(clamped.y, 10, accuracy: 1)
    }

    func testClamp_hugelyOutOfBounds_throws() {
        // >200 px outside any conceivable display.
        let point = CGPoint(x: 100_000, y: 100_000)
        // On headless CI (no NSScreen), clamp() passes through — only assert
        // the throw when we actually have screens to clamp against.
        guard !NSScreen.screens.isEmpty else {
            let result = try? GestureExecutor.clamp(point: point)
            XCTAssertNotNil(result, "headless environment should pass through")
            return
        }
        XCTAssertThrowsError(try GestureExecutor.clamp(point: point)) { error in
            guard case GestureError.pointOutOfBounds = error else {
                XCTFail("Expected .pointOutOfBounds, got \(error)")
                return
            }
        }
    }

    func testClamp_slightlyOutOfBounds_isClampedNotRejected() throws {
        // Up to 200 px of slack is clamped, not rejected.
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("No screens available (CI/headless).")
        }
        let w = screen.frame.width
        let slightlyOver = CGPoint(x: w + 50, y: 0)
        let clamped = try GestureExecutor.clamp(point: slightlyOver)
        XCTAssertLessThan(clamped.x, w, "point should be clamped inside the screen")
    }

    // MARK: - flipY involution

    func testFlipY_isItsOwnInverse() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("No screens available (CI/headless).")
        }
        let original = CGPoint(x: 123, y: 456)
        let flipped = GestureExecutor.flipY(original, screen: screen)
        let roundTripped = GestureExecutor.flipY(flipped, screen: screen)
        XCTAssertEqual(roundTripped.x, original.x, accuracy: 0.001)
        XCTAssertEqual(roundTripped.y, original.y, accuracy: 0.001)
    }

    // MARK: - planTyping

    func testPlanTyping_plainASCII_hello() {
        let plan = GestureExecutor.planTyping(text: "Hello")
        XCTAssertEqual(plan.count, 5)
        // 'H' is shifted: keyCode 0x04 with Shift modifier.
        if case .keyCode(let code, let mods) = plan[0].mode {
            XCTAssertEqual(code, 0x04)
            XCTAssertTrue(mods.contains(.shift))
        } else {
            XCTFail("First step should be a keyCode step, got \(plan[0])")
        }
        // 'e' is unshifted (0x0E).
        if case .keyCode(let code, let mods) = plan[1].mode {
            XCTAssertEqual(code, 0x0E)
            XCTAssertFalse(mods.contains(.shift))
        } else {
            XCTFail("Second step should be a keyCode step")
        }
        // 'l' is 0x25, 'o' is 0x1F.
        if case .keyCode(let code, _) = plan[2].mode {
            XCTAssertEqual(code, 0x25)
        }
        if case .keyCode(let code, _) = plan[3].mode {
            XCTAssertEqual(code, 0x25)
        }
        if case .keyCode(let code, _) = plan[4].mode {
            XCTAssertEqual(code, 0x1F)
        }
    }

    func testPlanTyping_emptyString_returnsEmptyPlan() {
        let plan = GestureExecutor.planTyping(text: "")
        XCTAssertTrue(plan.isEmpty)
    }

    func testPlanTyping_unicodeCharacter_usesUnicodeInjectionMode() {
        // 'é' is outside the US-ANSI ASCII table → unicode injection path.
        let plan = GestureExecutor.planTyping(text: "é")
        XCTAssertEqual(plan.count, 1)
        if case .unicode = plan[0].mode {
            // good
        } else {
            XCTFail("Expected .unicode injection for 'é', got \(plan[0])")
        }
    }

    func testPlanTyping_mixedASCIIAndUnicode() {
        let plan = GestureExecutor.planTyping(text: "a🎉b")
        XCTAssertEqual(plan.count, 3)
        if case .keyCode(let code, _) = plan[0].mode {
            XCTAssertEqual(code, 0x00, "'a' → 0x00")
        }
        if case .unicode = plan[1].mode {
            // good — emoji goes through unicode injection
        } else {
            XCTFail("Expected .unicode for emoji")
        }
        if case .keyCode(let code, _) = plan[2].mode {
            XCTAssertEqual(code, 0x0B, "'b' → 0x0B")
        }
    }

    func testPlanTyping_spaceAndNewline() {
        let plan = GestureExecutor.planTyping(text: " \n")
        XCTAssertEqual(plan.count, 2)
        if case .keyCode(let code, _) = plan[0].mode {
            XCTAssertEqual(code, 0x31, "space → 0x31")
        }
        if case .keyCode(let code, _) = plan[1].mode {
            XCTAssertEqual(code, 0x24, "newline → enter (0x24)")
        }
    }

    // MARK: - Accessibility Trust (read-only)

    func testIsAccessibilityTrusted_returnsBool() {
        // Just ensure the call doesn't crash. In test harness it's typically false.
        _ = GestureExecutor.isAccessibilityTrusted
    }
}
