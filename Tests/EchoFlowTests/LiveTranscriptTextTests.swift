import XCTest
@testable import EchoFlowCore

final class LiveTranscriptTextTests: XCTestCase {
    func testVolatileTextUpdatesWithoutDuplicatingFinalText() {
        var transcript = LiveTranscriptText()

        transcript.consume(text: "Email Alex", isFinal: false)
        XCTAssertEqual(transcript.visibleText, "Email Alex")

        transcript.consume(text: "Email Alex about the launch", isFinal: false)
        XCTAssertEqual(transcript.visibleText, "Email Alex about the launch")

        transcript.consume(text: "Email Alex about the launch.", isFinal: true)
        XCTAssertEqual(transcript.finalizedText, "Email Alex about the launch.")
        XCTAssertEqual(transcript.volatileText, "")
        XCTAssertEqual(transcript.visibleText, "Email Alex about the launch.")
    }

    func testFinalSegmentsAreJoinedAndEmptyFinalClearsVolatileText() {
        var transcript = LiveTranscriptText()

        transcript.consume(text: "First sentence.", isFinal: true)
        transcript.consume(text: "Second sentence.", isFinal: true)
        XCTAssertEqual(transcript.finalizedText, "First sentence. Second sentence.")

        transcript.consume(text: "Maybe another word", isFinal: false)
        transcript.consume(text: "", isFinal: true)
        XCTAssertEqual(transcript.visibleText, "First sentence. Second sentence.")
    }
}
