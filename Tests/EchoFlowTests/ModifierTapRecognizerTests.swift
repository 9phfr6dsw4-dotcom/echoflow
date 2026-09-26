import XCTest
@testable import EchoFlowCore

final class ModifierTapRecognizerTests: XCTestCase {
    func testBareModifierTapTogglesOnlyOnRelease() {
        var recognizer = ModifierTapRecognizer()

        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: false)))
        XCTAssertEqual(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)), .toggleRecording)
    }

    func testModifierChordDoesNotToggle() {
        var recognizer = ModifierTapRecognizer()

        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: false)))
        XCTAssertNil(recognizer.consume(.otherKeyDown))
        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)))
    }

    func testModifierPressedAlongsideAnotherModifierDoesNotToggle() {
        var recognizer = ModifierTapRecognizer()

        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: true)))
        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)))
    }

    func testUnmatchedReleaseDoesNotToggle() {
        var recognizer = ModifierTapRecognizer()

        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)))
    }

    func testHoldToTalkStartsOnPressAndStopsOnRelease() {
        var recognizer = ModifierTapRecognizer(mode: .holdToTalk)

        XCTAssertEqual(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: false)), .startRecording)
        XCTAssertEqual(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)), .stopRecording)
    }

    func testHoldToTalkChordStopsAndDoesNotRestartOnRelease() {
        var recognizer = ModifierTapRecognizer(mode: .holdToTalk)

        XCTAssertEqual(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: false)), .startRecording)
        XCTAssertEqual(recognizer.consume(.otherKeyDown), .stopRecording)
        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)))
    }

    func testHoldToTalkDoesNotStartWhenPressedWithAnotherModifier() {
        var recognizer = ModifierTapRecognizer(mode: .holdToTalk)

        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: true, hasOtherModifiers: true)))
        XCTAssertNil(recognizer.consume(.modifierChanged(isDown: false, hasOtherModifiers: false)))
    }
}
