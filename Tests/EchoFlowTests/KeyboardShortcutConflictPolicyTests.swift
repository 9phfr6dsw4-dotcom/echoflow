import XCTest
@testable import EchoFlowCore

final class KeyboardShortcutConflictPolicyTests: XCTestCase {
    func testDetectsOverlapWithReservedLegacyModifierHotkey() throws {
        let memo = try shortcut(keyCode: 46, modifiers: [.command, .shift, .control])

        XCTAssertTrue(KeyboardShortcutConflictPolicy.conflicts(
            memo,
            with: [],
            reservedModifierFlags: .control
        ))
        XCTAssertFalse(KeyboardShortcutConflictPolicy.conflicts(
            memo,
            with: [],
            reservedModifierFlags: .option
        ))
    }

    func testDetectsIdenticalKeyAndModifierChordsRegardlessOfDisplayLabel() throws {
        let first = try shortcut(keyCode: 46, modifiers: [.command, .shift], label: "⌘⇧M")
        let second = try shortcut(keyCode: 46, modifiers: [.command, .shift], label: "Command-Shift-M")

        XCTAssertTrue(KeyboardShortcutConflictPolicy.conflicts(first, with: [second]))
    }

    func testAllowsSameKeyWithDifferentModifierChord() throws {
        let first = try shortcut(keyCode: 46, modifiers: [.command, .shift])
        let second = try shortcut(keyCode: 46, modifiers: [.command, .option])

        XCTAssertFalse(KeyboardShortcutConflictPolicy.conflicts(first, with: [second]))
    }

    private func shortcut(
        keyCode: UInt16,
        modifiers: KeyboardShortcutModifierFlags,
        label: String? = nil
    ) throws -> KeyboardShortcutDescriptor {
        try XCTUnwrap(KeyboardShortcutDescriptor(
            keyCode: keyCode,
            requiredModifierFlags: modifiers,
            displayLabel: label
        ))
    }
}
