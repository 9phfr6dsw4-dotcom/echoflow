import XCTest
@testable import EchoFlowCore

final class AccessibilityInsertionVerificationTests: XCTestCase {
    private func state(_ count: Int?, _ location: Int?, _ length: Int = 0) -> AccessibilityEditState {
        AccessibilityEditState(
            characterCount: count,
            selectedRange: location.flatMap { InsertedTextCorrectionRange(location: $0, length: length) }
        )
    }

    func testGrowingFieldIsAnInsertion() {
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(10, 10), after: state(15, 15)),
            .changed
        )
    }

    func testReplacingASelectionOfEqualLengthIsDetectedByTheCaret() {
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(10, 2, 5), after: state(10, 7, 0)),
            .changed
        )
    }

    func testUnchangedFieldMeansTheInsertionWasIgnored() {
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(10, 10), after: state(10, 10)),
            .unchanged
        )
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(0, nil), after: state(0, nil)),
            .unchanged
        )
    }

    func testFieldWithoutLengthOrCaretCannotBeVerified() {
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(nil, nil), after: state(nil, nil)),
            .unverifiable
        )
        XCTAssertEqual(
            AccessibilityInsertionVerification.check(before: state(10, nil), after: state(nil, 12)),
            .unverifiable
        )
    }
}
