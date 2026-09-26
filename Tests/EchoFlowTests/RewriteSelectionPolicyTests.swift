import Foundation
import XCTest
@testable import EchoFlowCore

final class RewriteSelectionPolicyTests: XCTestCase {
    func testAllowsASelectedRangeInAnEligibleTextField() {
        let selection = makeSelection(text: "Original sentence.", location: 12, length: 18)

        XCTAssertEqual(RewriteSelectionPolicy.captureDecision(for: selection), .allowed)
        XCTAssertTrue(RewriteSelectionPolicy.canReplace(
            captured: selection,
            current: selection,
            sameFocusedElement: true
        ))
    }

    func testRejectsNoSelectionAndInconsistentAccessibilityRange() {
        XCTAssertEqual(
            RewriteSelectionPolicy.captureDecision(for: makeSelection(text: "  ", location: 0, length: 2)),
            .noSelection
        )
        XCTAssertEqual(
            RewriteSelectionPolicy.captureDecision(for: makeSelection(text: "hello", location: 0, length: 4)),
            .invalidRange
        )
    }

    func testRejectsSecureFieldsAndExcludedApplications() {
        let secure = makeSelection(text: "secret", location: 0, length: 6, role: "AXTextField", subrole: "AXSecureTextField")
        let passwordManager = makeSelection(text: "private", location: 0, length: 7, bundleIdentifier: "com.1password.1password")

        XCTAssertEqual(RewriteSelectionPolicy.captureDecision(for: secure), .secureField)
        XCTAssertEqual(RewriteSelectionPolicy.captureDecision(for: passwordManager), .excludedApplication)
    }

    func testTargetPreflightRejectsSecureExcludedAndUnsupportedFields() {
        XCTAssertEqual(
            RewriteSelectionPolicy.targetDecision(
                for: makeSelection(text: "secret", location: 0, length: 6, role: "AXTextField", subrole: "AXSecureTextField").target
            ),
            .secureField
        )
        XCTAssertEqual(
            RewriteSelectionPolicy.targetDecision(
                for: makeSelection(text: "private", location: 0, length: 7, bundleIdentifier: "com.1password.1password").target
            ),
            .excludedApplication
        )
        XCTAssertEqual(
            RewriteSelectionPolicy.targetDecision(
                for: makeSelection(text: "button", location: 0, length: 6, role: "AXButton").target
            ),
            .unsupportedField
        )
    }

    func testExclusionPolicyUnavailableFailsClosedBeforeSelectionRead() {
        let selection = makeSelection(text: "private", location: 0, length: 7)

        XCTAssertEqual(
            RewriteSelectionPolicy.captureDecision(
                for: selection,
                additionalExcludedBundleIdentifiers: nil
            ),
            .policyUnavailable
        )
        XCTAssertEqual(
            RewriteSelectionPolicy.targetDecision(
                for: selection.target,
                additionalExcludedBundleIdentifiers: nil
            ),
            .policyUnavailable
        )
    }

    func testRejectsNonTextControlsAndOversizedSelection() {
        XCTAssertEqual(
            RewriteSelectionPolicy.captureDecision(for: makeSelection(text: "button", location: 0, length: 6, role: "AXButton")),
            .unsupportedField
        )
        let oversizedText = String(repeating: "x", count: RewriteSelectionPolicy.maximumSelectionCharacters + 1)
        XCTAssertEqual(
            RewriteSelectionPolicy.captureDecision(for: makeSelection(text: oversizedText, location: 0, length: oversizedText.utf16.count)),
            .selectionTooLarge
        )
    }

    func testReplacementRequiresSameFieldAndExactSelectedTextAndRange() {
        let captured = makeSelection(text: "Original", location: 5, length: 8)
        let changedText = makeSelection(text: "Changed!", location: 5, length: 8)
        let changedRange = makeSelection(text: "Original", location: 6, length: 8)
        let changedApplication = makeSelection(text: "Original", location: 5, length: 8, bundleIdentifier: "com.example.other")

        XCTAssertFalse(RewriteSelectionPolicy.canReplace(captured: captured, current: changedText, sameFocusedElement: true))
        XCTAssertFalse(RewriteSelectionPolicy.canReplace(captured: captured, current: changedRange, sameFocusedElement: true))
        XCTAssertFalse(RewriteSelectionPolicy.canReplace(captured: captured, current: changedApplication, sameFocusedElement: true))
        XCTAssertFalse(RewriteSelectionPolicy.canReplace(captured: captured, current: captured, sameFocusedElement: false))
    }

    func testRejectsSelectionRangeExtendingPastTheFieldEnd() {
        let selection = makeSelection(
            text: "hi",
            location: 4,
            length: 2,
            fieldCharacterCount: 5
        )
        XCTAssertEqual(RewriteSelectionPolicy.captureDecision(for: selection), .invalidRange)
    }

    func testCountsAccessibilityRangeInUTF16Units() {
        let emoji = makeSelection(text: "🌟", location: 0, length: 2)

        XCTAssertEqual(RewriteSelectionPolicy.captureDecision(for: emoji), .allowed)
    }

    private func makeSelection(
        text: String,
        location: Int,
        length: Int,
        role: String = "AXTextArea",
        subrole: String? = nil,
        bundleIdentifier: String = "com.example.editor",
        fieldCharacterCount: Int? = nil
    ) -> RewriteSelectionSnapshot {
        RewriteSelectionSnapshot(
            target: TextInsertionSnapshot(
                processIdentifier: 42,
                bundleIdentifier: bundleIdentifier,
                focusedRole: role,
                focusedSubrole: subrole
            ),
            selectedText: text,
            rangeLocation: location,
            rangeLength: length,
            fieldCharacterCount: fieldCharacterCount ?? max(location, 0) + max(length, 0)
        )
    }
}

final class VoiceRewritePolicyTests: XCTestCase {
    func testCreatesRequestWithBothSelectedTextAndVoiceInstruction() throws {
        let request = try XCTUnwrap(VoiceRewritePolicy.request(
            selectedText: "The original paragraph.",
            instruction: "Make this shorter."
        ))

        XCTAssertEqual(request.selectedText, "The original paragraph.")
        XCTAssertEqual(request.instruction, "Make this shorter.")
    }

    func testRejectsEmptyAndOversizedRewriteInputs() {
        XCTAssertNil(VoiceRewritePolicy.request(selectedText: "  ", instruction: "Make it shorter"))
        XCTAssertNil(VoiceRewritePolicy.request(selectedText: "Text", instruction: "\n "))
        XCTAssertNil(VoiceRewritePolicy.request(
            selectedText: String(repeating: "x", count: VoiceRewritePolicy.maximumInputCharacters + 1),
            instruction: "Rewrite"
        ))
        XCTAssertNil(VoiceRewritePolicy.request(
            selectedText: "Text",
            instruction: String(repeating: "x", count: VoiceRewritePolicy.maximumInstructionCharacters + 1)
        ))
    }

    func testAcceptsOnlyNonemptyBoundedModelOutputWithoutTrimmingIt() {
        XCTAssertEqual(VoiceRewritePolicy.validOutput("  Rewritten text\n"), "  Rewritten text\n")
        XCTAssertNil(VoiceRewritePolicy.validOutput(" \n "))
        XCTAssertNil(VoiceRewritePolicy.validOutput(String(repeating: "x", count: VoiceRewritePolicy.maximumOutputCharacters + 1)))
    }
}
