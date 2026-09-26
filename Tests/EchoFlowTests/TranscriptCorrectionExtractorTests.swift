import Foundation
import XCTest
@testable import EchoFlowCore

final class TranscriptCorrectionExtractorTests: XCTestCase {
    func testStandaloneSingleTokenReplacementIsReturned() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(from: "Kubernets", to: "Kubernetes"),
            [TranscriptCorrection(original: "Kubernets", replacement: "Kubernetes")]
        )
    }

    func testExactNoOpReturnsNoCorrections() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Please send the report tomorrow.",
                to: "Please send the report tomorrow."
            ),
            []
        )
    }

    func testSingleTokenReplacementIsReturned() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "I use Kubernets daily.",
                to: "I use Kubernetes daily."
            ),
            [TranscriptCorrection(original: "Kubernets", replacement: "Kubernetes")]
        )
    }

    func testIndependentSingleTokenReplacementsAreReturned() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Kubernets works with Acmee after lunch.",
                to: "Kubernetes works with Acme after lunch."
            ),
            [
                TranscriptCorrection(original: "Kubernets", replacement: "Kubernetes"),
                TranscriptCorrection(original: "Acmee", replacement: "Acme")
            ]
        )
    }

    func testInsertionIsNotInferredAsACorrection() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Send report today.",
                to: "Send the report today."
            ),
            []
        )
    }

    func testDeletionIsNotInferredAsACorrection() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Send the report today.",
                to: "Send report today."
            ),
            []
        )
    }

    func testMultiTokenPhraseChangesAreNotInferredAsCorrections() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Acme ships product today.",
                to: "North Star ships product today."
            ),
            []
        )
    }

    func testAmbiguousRepeatedTokenAlignmentIsIgnored() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Acme Acmee Acme",
                to: "Acme Acme Acme"
            ),
            []
        )
    }

    func testPunctuationAndCaseDifferencesAreNormalized() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "HELLO, Kubernets!",
                to: "hello; Kubernetes."
            ),
            [TranscriptCorrection(original: "Kubernets", replacement: "Kubernetes")]
        )
    }

    func testShortAndCommonWordCorrectionsAreFiltered() {
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "Use AI today.",
                to: "Use Acme today."
            ),
            []
        )
        XCTAssertEqual(
            TranscriptCorrectionExtractor.extract(
                from: "That is teh answer.",
                to: "That is the answer."
            ),
            []
        )
    }

    func testCorrectionCodableRoundTrip() throws {
        let correction = TranscriptCorrection(original: "Kubernets", replacement: "Kubernetes")
        let data = try JSONEncoder().encode(correction)

        XCTAssertEqual(try JSONDecoder().decode(TranscriptCorrection.self, from: data), correction)
    }
}
