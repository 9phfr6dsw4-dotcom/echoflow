import XCTest
@testable import EchoFlowCore

final class RecordingActionEventPolicyTests: XCTestCase {
    func testMismatchedStopIsIgnoredWhileAnotherActionIsStarting() {
        XCTAssertEqual(
            RecordingActionEventPolicy.decision(
                requestedAction: .dictation,
                pendingAction: .voiceMemo,
                activeAction: .dictation
            ),
            .ignore
        )
    }

    func testMatchingStopCancelsItsPendingStart() {
        XCTAssertEqual(
            RecordingActionEventPolicy.decision(
                requestedAction: .voiceMemo,
                pendingAction: .voiceMemo,
                activeAction: .dictation
            ),
            .cancelPendingStart
        )
    }

    func testStopTargetsOnlyTheMatchingActiveActionWhenNoStartIsPending() {
        XCTAssertEqual(
            RecordingActionEventPolicy.decision(
                requestedAction: .rewrite,
                pendingAction: nil,
                activeAction: .rewrite
            ),
            .stopActiveRecording
        )
        XCTAssertEqual(
            RecordingActionEventPolicy.decision(
                requestedAction: .dictation,
                pendingAction: nil,
                activeAction: .rewrite
            ),
            .ignore
        )
    }
}
