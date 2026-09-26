import Foundation
import XCTest
@testable import EchoFlowCore

final class KeyboardShortcutRecognizerTests: XCTestCase {
    func testTapToToggleFiresOnceForMatchingShortcutPress() throws {
        var recognizer = KeyboardShortcutRecognizer(primary: try shortcut(keyCode: 10, modifiers: .command))

        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .toggleRecording)
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 10)))
    }

    func testHoldToTalkStartsOnPressAndStopsOnRelease() throws {
        var recognizer = KeyboardShortcutRecognizer(
            primary: try shortcut(keyCode: 10, modifiers: .command),
            mode: .holdToTalk
        )

        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .startRecording)
        XCTAssertEqual(recognizer.consume(.keyUp(keyCode: 10)), .stopRecording)
    }

    func testEnabledBackupUsesHoldToTalkActions() throws {
        var recognizer = KeyboardShortcutRecognizer(
            primary: try shortcut(keyCode: 10, modifiers: .command),
            backup: try shortcut(keyCode: 11, modifiers: .shift),
            isBackupEnabled: true,
            mode: .holdToTalk
        )

        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 11, modifierFlags: .shift, isRepeat: false)), .startRecording)
        XCTAssertEqual(recognizer.consume(.keyUp(keyCode: 11)), .stopRecording)
    }

    func testIgnoresUnrelatedKeysAndModifierChordMismatches() throws {
        var recognizer = KeyboardShortcutRecognizer(primary: try shortcut(keyCode: 10, modifiers: .command))

        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 11, modifierFlags: .command, isRepeat: false)))
        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: [.command, .shift], isRepeat: false)))
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 10)))
    }

    func testIgnoresKeyRepeatsAndDoesNotFireAgainUntilANewPress() throws {
        var recognizer = KeyboardShortcutRecognizer(primary: try shortcut(keyCode: 10, modifiers: .command))

        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: true)))
        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .toggleRecording)
        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: true)))
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 10)))
        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .toggleRecording)
    }

    func testEnabledBackupTriggersSameActionAsPrimaryWithoutDuplicateFiring() throws {
        var recognizer = KeyboardShortcutRecognizer(
            primary: try shortcut(keyCode: 10, modifiers: .command),
            backup: try shortcut(keyCode: 11, modifiers: [.command, .shift]),
            isBackupEnabled: true
        )

        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 11, modifierFlags: [.command, .shift], isRepeat: false)), .toggleRecording)
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 11)))
        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .toggleRecording)
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 10)))
    }

    func testBackupIsIgnoredWhenDisabled() throws {
        var recognizer = KeyboardShortcutRecognizer(
            primary: try shortcut(keyCode: 10, modifiers: .command),
            backup: try shortcut(keyCode: 11, modifiers: .shift),
            isBackupEnabled: false
        )

        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 11, modifierFlags: .shift, isRepeat: false)))
    }

    func testPrimaryAndBackupPressedTogetherDoNotFireTwiceForOneGesture() throws {
        var recognizer = KeyboardShortcutRecognizer(
            primary: try shortcut(keyCode: 10, modifiers: .command),
            backup: try shortcut(keyCode: 11, modifiers: .command),
            isBackupEnabled: true
        )

        XCTAssertEqual(recognizer.consume(.keyDown(keyCode: 10, modifierFlags: .command, isRepeat: false)), .toggleRecording)
        XCTAssertNil(recognizer.consume(.keyDown(keyCode: 11, modifierFlags: .command, isRepeat: false)))
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 10)))
        XCTAssertNil(recognizer.consume(.keyUp(keyCode: 11)))
    }

    func testShortcutDescriptorCodableRoundTripsAndRequiresModifier() throws {
        let descriptor = try shortcut(keyCode: 42, modifiers: [.command, .option], displayLabel: "⌘⌥K")
        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(KeyboardShortcutDescriptor.self, from: encoded)

        XCTAssertEqual(decoded, descriptor)
        XCTAssertNil(KeyboardShortcutDescriptor(keyCode: 42, requiredModifierFlags: []))
    }

    private func shortcut(
        keyCode: UInt16,
        modifiers: KeyboardShortcutModifierFlags,
        displayLabel: String? = nil
    ) throws -> KeyboardShortcutDescriptor {
        try XCTUnwrap(
            KeyboardShortcutDescriptor(
                keyCode: keyCode,
                requiredModifierFlags: modifiers,
                displayLabel: displayLabel
            )
        )
    }
}
