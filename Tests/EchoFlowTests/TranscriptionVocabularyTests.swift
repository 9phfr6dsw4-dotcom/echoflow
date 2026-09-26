import XCTest
@testable import EchoFlowCore

final class TranscriptionVocabularyTests: XCTestCase {
    func testCombinesCustomAndLearnedTermsWithoutDuplicates() {
        let terms = TranscriptionVocabulary.terms(
            customTerms: ["EchoFlow", "Jordan  Lee"],
            learnedTerms: [
                makeLearnedTerm("ECHOFLOW", pinned: false),
                makeLearnedTerm("Parakeet", pinned: false)
            ]
        )

        XCTAssertEqual(terms, ["EchoFlow", "Jordan Lee", "Parakeet"])
    }

    func testPinnedLearnedTermsArePrioritizedWithinAppleLimit() {
        let customTerms = (0..<3).map { "Custom \($0)" }
        let learnedTerms = [
            makeLearnedTerm("Pinned Name", pinned: true),
            makeLearnedTerm("Unpinned Name", pinned: false)
        ]

        let terms = TranscriptionVocabulary.terms(
            customTerms: customTerms,
            learnedTerms: learnedTerms,
            maximumCount: 2
        )

        XCTAssertEqual(terms, ["Pinned Name", "Custom 0"])
    }

    func testIgnoresBlankTermsAndNormalizesWhitespace() {
        let terms = TranscriptionVocabulary.terms(
            customTerms: ["  ", " Ada   Lovelace ", "ada lovelace"],
            learnedTerms: []
        )

        XCTAssertEqual(terms, ["Ada Lovelace"])
    }

    func testWhisperPromptUsesOnlyProvidedVocabularyTerms() {
        XCTAssertEqual(
            TranscriptionVocabulary.whisperPromptText(from: ["EchoFlow", "Ada Lovelace"]),
            "EchoFlow, Ada Lovelace"
        )
    }

    private func makeLearnedTerm(_ term: String, pinned: Bool) -> LocalLearnedTerm {
        var store = LocalLearningStore()
        for _ in 0..<LocalLearningPolicy.minimumCorrectionOccurrences {
            _ = store.observeCorrection(original: "misheard", replacement: term)
        }
        if pinned {
            _ = store.setPinned(true, for: term)
        }
        return try! XCTUnwrap(store.learnedTerms.first)
    }
}
