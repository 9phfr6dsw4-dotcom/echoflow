import XCTest
@testable import EchoFlowCore

final class InsertedTextCorrectionScopeTests: XCTestCase {
    func testCapturesOnlyNonemptySelectionsInsideRecentlyInsertedText() throws {
        let scope = try XCTUnwrap(InsertedTextCorrectionScope(insertedText: "Hello Andromeda world", insertionLocation: 8))

        let candidate = scope.candidate(
            for: try range(14, 9),
            fieldCharacterCount: 40
        )

        XCTAssertEqual(candidate?.originalText, "Andromeda")
        XCTAssertEqual(candidate?.range, InsertedTextCorrectionRange(location: 14, length: 9))
        let outsideStart = try range(7, 2)
        let outsideEnd = try range(28, 2)
        let empty = try range(14, 0)
        XCTAssertNil(scope.candidate(for: outsideStart, fieldCharacterCount: 40))
        XCTAssertNil(scope.candidate(for: outsideEnd, fieldCharacterCount: 40))
        XCTAssertNil(scope.candidate(for: empty, fieldCharacterCount: 40))
    }

    func testAllowsAReplacementRangeOnlyWhenCaretMatchesTheExactLengthDelta() throws {
        let scope = try XCTUnwrap(InsertedTextCorrectionScope(insertedText: "Hello Andromeda world", insertionLocation: 8))
        let candidate = try XCTUnwrap(scope.candidate(
            for: try range(14, 9),
            fieldCharacterCount: 40
        ))

        XCTAssertEqual(
            scope.replacementRange(for: candidate, currentFieldCharacterCount: 43, caretLocation: 26),
            InsertedTextCorrectionRange(location: 14, length: 12)
        )
        XCTAssertNil(scope.replacementRange(for: candidate, currentFieldCharacterCount: 43, caretLocation: 25))
    }

    func testRejectsDeletionAndInvalidOrOutOfFieldRanges() throws {
        let scope = try XCTUnwrap(InsertedTextCorrectionScope(insertedText: "Andromeda", insertionLocation: 5))
        let candidate = try XCTUnwrap(scope.candidate(
            for: try range(5, 9),
            fieldCharacterCount: 14
        ))

        let outOfField = try range(5, 9)
        XCTAssertNil(scope.replacementRange(for: candidate, currentFieldCharacterCount: 5, caretLocation: 5))
        XCTAssertNil(scope.candidate(for: outOfField, fieldCharacterCount: 10))
        XCTAssertNil(InsertedTextCorrectionScope(insertedText: "", insertionLocation: 0))
        XCTAssertNil(InsertedTextCorrectionScope(insertedText: "word", insertionLocation: -1))
        XCTAssertNil(InsertedTextCorrectionRange(location: -1, length: 1))
        XCTAssertNil(InsertedTextCorrectionRange(location: 1, length: -1))
    }

    func testUsesUTF16OffsetsForNonASCIIInsertedText() throws {
        let scope = try XCTUnwrap(InsertedTextCorrectionScope(insertedText: "😀 café", insertionLocation: 3))
        let candidate = scope.candidate(
            for: try range(6, 4),
            fieldCharacterCount: 13
        )

        XCTAssertEqual(candidate?.originalText, "café")
    }

    private func range(_ location: Int, _ length: Int) throws -> InsertedTextCorrectionRange {
        try XCTUnwrap(InsertedTextCorrectionRange(location: location, length: length))
    }
}
