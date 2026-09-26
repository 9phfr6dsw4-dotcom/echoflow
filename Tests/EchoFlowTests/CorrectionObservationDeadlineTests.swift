import XCTest
@testable import EchoFlowCore

final class CorrectionObservationDeadlineTests: XCTestCase {
    func testObservationClosesAtDeadline() {
        let clock = ContinuousClock()
        let now = clock.now
        let deadline = now.advanced(by: .seconds(10))

        XCTAssertTrue(CorrectionObservationDeadlinePolicy.isOpen(deadline: deadline, now: now))
        XCTAssertFalse(CorrectionObservationDeadlinePolicy.isOpen(deadline: deadline, now: deadline))
        XCTAssertFalse(CorrectionObservationDeadlinePolicy.isOpen(
            deadline: deadline,
            now: deadline.advanced(by: .nanoseconds(1))
        ))
    }
}
