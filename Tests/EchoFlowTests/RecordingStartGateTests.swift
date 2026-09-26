import XCTest
@testable import EchoFlowCore

final class RecordingStartGateTests: XCTestCase {
    func testCancelInvalidatesPendingStartAndAllowsNextAfterItFinishes() throws {
        var gate = RecordingStartGate()
        let first = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.isCurrent(first))
        XCTAssertTrue(gate.cancelPending())
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertNil(gate.begin(), "Do not overlap a canceled request that is still unwinding")

        gate.finish(first)
        let second = try XCTUnwrap(gate.begin())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testCaptureRequiresCurrentStartAndNonExcludedForeground() {
        XCTAssertTrue(RecordingCaptureStartPolicy.canCapture(
            startIsCurrent: true,
            targetIsExcluded: false
        ))
        XCTAssertFalse(RecordingCaptureStartPolicy.canCapture(
            startIsCurrent: false,
            targetIsExcluded: false
        ))
        XCTAssertFalse(RecordingCaptureStartPolicy.canCapture(
            startIsCurrent: true,
            targetIsExcluded: true
        ))
    }

    func testEngineStartRequiresCurrentRequestAndCurrentMicrophoneAuthorization() {
        XCTAssertTrue(RecordingCaptureStartPolicy.canStartEngine(
            startIsCurrent: true,
            microphoneAuthorized: true
        ))
        XCTAssertFalse(RecordingCaptureStartPolicy.canStartEngine(
            startIsCurrent: false,
            microphoneAuthorized: true
        ))
        XCTAssertFalse(RecordingCaptureStartPolicy.canStartEngine(
            startIsCurrent: true,
            microphoneAuthorized: false
        ))
    }

    func testCancelDoesNothingWhenNoStartIsPending() {
        var gate = RecordingStartGate()
        XCTAssertFalse(gate.cancelPending())
    }
}
