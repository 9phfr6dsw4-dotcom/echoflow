import XCTest
@testable import EchoFlowCore

final class ParakeetTentativeTranscriptTests: XCTestCase {
    func testOnlyActiveRecordingCanPublishTentativeWords() {
        var state = ParakeetTentativeTranscript()
        let first = state.begin()
        XCTAssertTrue(state.accept("  hello ", for: first))
        XCTAssertEqual(state.text, "hello")
        state.stop(first)
        XCTAssertEqual(state.text, "")
        XCTAssertFalse(state.accept("late", for: first))

        let second = state.begin()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.accept("old", for: first))
        XCTAssertTrue(state.accept("new", for: second))
        XCTAssertEqual(state.text, "new")
        state.stop(first)
        XCTAssertEqual(state.text, "new")
        state.stop(second)
        XCTAssertEqual(state.text, "")
    }

    func testCancelInvalidatesAnyInFlightUpdate() {
        var state = ParakeetTentativeTranscript()
        let token = state.begin()
        state.stop(token)
        XCTAssertFalse(state.accept("never pasted", for: token))
        XCTAssertEqual(state.text, "")
    }
}
