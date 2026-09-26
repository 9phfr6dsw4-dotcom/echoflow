import XCTest
@testable import EchoFlowCore

final class TextInsertionPolicyTests: XCTestCase {
    private let policy = TextInsertionPolicy()

    func testDiagnosticIncludesAppsFocusAndSkipReason() {
        let diagnostic = TextInsertionDiagnostic(
            appAtDictationStop: "ChatGPT",
            appWhenTextWasReady: "Claude",
            focusedElementAtStop: "AXTextArea",
            focusedElementWhenReady: "Unavailable (Accessibility API did not expose the focused element)",
            insertionResult: "The frontmost app changed between dictation stop and text insertion."
        )

        XCTAssertEqual(
            diagnostic.description,
            "App at dictation stop: ChatGPT\nApp when text was ready: Claude\nFocused element at stop: AXTextArea\nFocused element when ready: Unavailable (Accessibility API did not expose the focused element)\nInsertion result: The frontmost app changed between dictation stop and text insertion."
        )
    }

    func testDiagnosticDescribesInsertionWithoutClipboardClaims() {
        let diagnostic = TextInsertionDiagnostic(
            appAtDictationStop: "Claude",
            appWhenTextWasReady: "Claude",
            focusedElementAtStop: "AXTextArea",
            focusedElementWhenReady: "AXTextArea",
            insertionResult: "Unicode text input was sent; app acceptance cannot be confirmed."
        )

        XCTAssertTrue(diagnostic.description.contains("Insertion result: Unicode text input was sent"))
        XCTAssertFalse(diagnostic.description.localizedCaseInsensitiveContains("clipboard"))
        XCTAssertFalse(diagnostic.description.contains("Command-V"))
    }

    func testVerifiedTextInputUsesAccessibilityInsertion() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXTextArea"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .insert
        )
    }

    func testEditableComboBoxUsesAccessibilityInsertion() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.Safari",
            focusedRole: "AXComboBox",
            focusedElementIsEditable: true
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .insert
        )
    }

    func testSafariComboBoxUsesKeyboardFallbackWhenEditabilityIsFalseOrUnavailable() {
        for isEditable in [false, nil] {
            let target = TextInsertionSnapshot(
                processIdentifier: 42,
                bundleIdentifier: "com.apple.Safari",
                focusedRole: "AXComboBox",
                focusedElementIsEditable: isEditable
            )

            XCTAssertEqual(
                policy.decision(captured: target, current: target, sameFocusedElement: true),
                .keyboardEventFallback
            )
            XCTAssertEqual(
                policy.decision(captured: target, current: target, sameFocusedElement: false),
                .blocked(.unsupportedField)
            )
        }
    }

    func testNonEditableComboBoxOutsideSafariRemainsBlocked() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXComboBox",
            focusedElementIsEditable: false
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .blocked(.unsupportedField)
        )
    }

    func testMicrosoftWordSplitGroupUsesKeyboardFallbackOnlyWhileSameElementStaysFocused() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.Word",
            focusedRole: "AXSplitGroup"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .keyboardEventFallback
        )
        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: false),
            .blocked(.unsupportedField)
        )

        let otherApp = TextInsertionSnapshot(
            processIdentifier: 84,
            bundleIdentifier: "com.apple.Safari",
            focusedRole: "AXSplitGroup"
        )
        XCTAssertEqual(
            policy.decision(captured: otherApp, current: otherApp, sameFocusedElement: true),
            .blocked(.unsupportedField)
        )
    }

    func testSecureTextFieldIsNeverEligible() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXSecureTextField"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .blocked(.secureField)
        )
    }

    func testChangedApplicationIsBlockedButSameAppFocusChangeUsesKeyboardFallback() {
        let captured = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXTextField"
        )
        let differentApp = TextInsertionSnapshot(
            processIdentifier: 84,
            bundleIdentifier: "com.example.mail",
            focusedRole: nil
        )
        let sameAppDifferentField = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXTextField"
        )

        XCTAssertEqual(policy.decision(captured: captured, current: differentApp, sameFocusedElement: false), .blocked(.targetChanged))
        XCTAssertEqual(policy.decision(captured: captured, current: sameAppDifferentField, sameFocusedElement: false), .keyboardEventFallback)
    }

    func testSameBundleIdentifierRemainsSameAppAcrossProcessChanges() {
        let beforeRestart = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXTextArea"
        )
        let afterRestart = TextInsertionSnapshot(
            processIdentifier: 84,
            bundleIdentifier: "COM.EXAMPLE.EDITOR",
            focusedRole: "AXTextArea"
        )

        XCTAssertTrue(policy.sameApplication(beforeRestart, afterRestart))
        XCTAssertEqual(
            policy.decision(captured: beforeRestart, current: afterRestart, sameFocusedElement: false),
            .keyboardEventFallback
        )
    }

    func testPasswordManagerIsExcludedEvenWhenItHasATextField() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.1password.1password",
            focusedRole: "AXTextField"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .blocked(.excludedApplication)
        )
    }

    func testUnknownFocusedControlIsBlockedInsteadOfKeyboardFallback() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXButton"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: false),
            .blocked(.unsupportedField)
        )
    }

    func testUnavailableFocusedRoleIsBlockedInsteadOfKeyboardFallback() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: nil
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: false),
            .blocked(.unsupportedField)
        )
    }

    func testMissingBundleIdentityFailsClosed() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: nil,
            focusedRole: "AXTextField"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .blocked(.policyUnavailable)
        )
    }

    func testAutoSendRequiresAccessibilityToConfirmInsertion() {
        XCTAssertTrue(TextInsertionPolicy.canSubmitAfterInsertion(
            autoSendEnabled: true,
            insertionConfirmedByAccessibility: true
        ))
        XCTAssertFalse(TextInsertionPolicy.canSubmitAfterInsertion(
            autoSendEnabled: true,
            insertionConfirmedByAccessibility: false
        ))
        XCTAssertFalse(TextInsertionPolicy.canSubmitAfterInsertion(
            autoSendEnabled: false,
            insertionConfirmedByAccessibility: true
        ))
    }

    func testUnavailableApplicationIsBlocked() {
        XCTAssertEqual(
            policy.decision(captured: nil, current: nil, sameFocusedElement: false),
            .blocked(.targetUnavailable)
        )
    }

    func testSecureFieldSubroleIsNeverEligible() {
        let target = TextInsertionSnapshot(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedRole: "AXTextField",
            focusedSubrole: "AXSecureTextField"
        )

        XCTAssertEqual(
            policy.decision(captured: target, current: target, sameFocusedElement: true),
            .blocked(.secureField)
        )
    }
}
