import XCTest
@testable import EchoFlowCore

final class RecordingDiscardGateTests: XCTestCase {
    func testRequestBlocksStartsAndStopsBeforeCleanupTaskBegins() {
        var gate = RecordingDiscardGate()

        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.blocksRecordingEvents)
        XCTAssertFalse(gate.request())
    }

    func testDiscardRemainsLatchedAcrossSuspendedCleanupUntilFinished() {
        var gate = RecordingDiscardGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.beginCleanup())

        XCTAssertTrue(gate.blocksRecordingEvents)
        XCTAssertFalse(gate.beginCleanup())

        gate.finishCleanup()
        XCTAssertFalse(gate.blocksRecordingEvents)
    }

    func testCleanupCannotBeginWithoutActivationOrStopRequest() {
        var gate = RecordingDiscardGate()
        XCTAssertFalse(gate.beginCleanup())
        XCTAssertFalse(gate.blocksRecordingEvents)
    }
}
