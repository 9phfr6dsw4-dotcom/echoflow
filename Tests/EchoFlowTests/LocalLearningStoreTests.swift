import Foundation
import XCTest
@testable import EchoFlowCore

final class LocalLearningStoreTests: XCTestCase {
    func testDefaultPolicyLearnsAutomaticallyOnlyAfterThreeMatchingCorrections() {
        var store = LocalLearningStore()

        XCTAssertFalse(store.policy.askBeforeAdding)
        XCTAssertEqual(
            store.observeCorrection(original: "kuberntes", replacement: "Kubernetes"),
            .counted(occurrences: 1)
        )
        XCTAssertEqual(
            store.observeCorrection(original: "kuberntes", replacement: "Kubernetes"),
            .counted(occurrences: 2)
        )
        XCTAssertTrue(store.learnedTerms.isEmpty)

        XCTAssertEqual(
            store.observeCorrection(original: "kuberntes", replacement: "Kubernetes"),
            .learned(term: "Kubernetes")
        )
        XCTAssertEqual(store.learnedTerms.map(\.term), ["Kubernetes"])
    }

    func testDifferentCorrectionPairsDoNotPoolOccurrences() {
        var store = LocalLearningStore()

        XCTAssertEqual(store.observeCorrection(original: "kuberntes", replacement: "Kubernetes"), .counted(occurrences: 1))
        XCTAssertEqual(store.observeCorrection(original: "Kubernets", replacement: "Kubernetes"), .counted(occurrences: 1))
        XCTAssertEqual(store.observeCorrection(original: "kuberntes", replacement: "Kubernetes"), .counted(occurrences: 2))
        XCTAssertEqual(store.observeCorrection(original: "Kubernets", replacement: "Kubernetes"), .counted(occurrences: 2))

        XCTAssertTrue(store.learnedTerms.isEmpty)
    }

    func testCommonStopwordsAndShortReplacementTokensAreIgnored() {
        var store = LocalLearningStore()
        let ignoredReplacements = ["I", "a", "an", "the", "one", "go", "AI", "  the  "]

        for replacement in ignoredReplacements {
            XCTAssertEqual(
                store.observeCorrection(original: "mistake", replacement: replacement),
                .ignored,
                "Expected \(replacement) to be ignored"
            )
        }

        XCTAssertTrue(store.learnedTerms.isEmpty)
        XCTAssertTrue(store.pendingAdditions.isEmpty)
    }

    func testAskBeforeAddingCreatesPendingItemUntilConfirmed() {
        var store = LocalLearningStore(policy: LocalLearningPolicy(askBeforeAdding: true))

        XCTAssertEqual(store.observeCorrection(original: "Acmee", replacement: "Acme"), .counted(occurrences: 1))
        XCTAssertEqual(store.observeCorrection(original: "Acmee", replacement: "Acme"), .counted(occurrences: 2))
        XCTAssertEqual(store.observeCorrection(original: "Acmee", replacement: "Acme"), .pendingConfirmation(term: "Acme"))
        XCTAssertTrue(store.learnedTerms.isEmpty)
        XCTAssertEqual(store.pendingAdditions.map(\.term), ["Acme"])

        XCTAssertTrue(store.confirmAddition(of: "Acme"))
        XCTAssertEqual(store.learnedTerms.map(\.term), ["Acme"])
        XCTAssertTrue(store.pendingAdditions.isEmpty)
    }

    func testRejectingPendingAdditionClearsItsCountBeforeFutureObservations() {
        var store = LocalLearningStore(policy: LocalLearningPolicy(askBeforeAdding: true))
        for _ in 0..<3 {
            _ = store.observeCorrection(original: "Acmee", replacement: "Acme")
        }
        XCTAssertEqual(store.pendingAdditions.map(\.term), ["Acme"])

        XCTAssertTrue(store.rejectAddition(of: "Acme"))
        XCTAssertTrue(store.pendingAdditions.isEmpty)
        XCTAssertTrue(store.learnedTerms.isEmpty)
        XCTAssertEqual(
            store.observeCorrection(original: "Acmee", replacement: "Acme"),
            .counted(occurrences: 1)
        )
    }

    func testLearnedTermsCanBePinnedUnpinnedAndRemoved() {
        var store = LocalLearningStore()
        for _ in 0..<3 {
            _ = store.observeCorrection(original: "Kubernets", replacement: "Kubernetes")
        }

        XCTAssertTrue(store.setPinned(true, for: "Kubernetes"))
        XCTAssertEqual(store.learnedTerms.first?.isPinned, true)
        XCTAssertTrue(store.setPinned(false, for: "Kubernetes"))
        XCTAssertEqual(store.learnedTerms.first?.isPinned, false)
        XCTAssertTrue(store.removeLearnedTerm("Kubernetes"))
        XCTAssertTrue(store.learnedTerms.isEmpty)
        XCTAssertFalse(store.setPinned(true, for: "Kubernetes"))
    }

    func testCodableRoundTripPreservesPolicyLearnedAndPendingState() throws {
        var store = LocalLearningStore(policy: LocalLearningPolicy(askBeforeAdding: true))
        for _ in 0..<3 {
            _ = store.observeCorrection(original: "Kubernets", replacement: "Kubernetes")
        }
        XCTAssertTrue(store.confirmAddition(of: "Kubernetes"))
        XCTAssertTrue(store.setPinned(true, for: "Kubernetes"))
        for _ in 0..<3 {
            _ = store.observeCorrection(original: "Acmee", replacement: "Acme")
        }

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(LocalLearningStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertTrue(decoded.policy.askBeforeAdding)
        XCTAssertEqual(decoded.learnedTerms.map(\.term), ["Kubernetes"])
        XCTAssertEqual(decoded.pendingAdditions.map(\.term), ["Acme"])
    }

    func testTranscriptPruningDoesNotRemoveSeparatelyPersistedLearnedTerms() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let learningURL = root.appendingPathComponent("local-learning.json")
        var learningStore = LocalLearningStore()
        for _ in 0..<3 {
            _ = learningStore.observeCorrection(original: "Kubernets", replacement: "Kubernetes")
        }
        try JSONEncoder().encode(learningStore).write(to: learningURL)

        let historyStore = TranscriptHistoryStore(
            applicationSupportDirectory: root,
            settings: TranscriptHistorySettings(retention: .thirtyDays)
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let expiredRecord = TranscriptRecord(
            text: "Old transcript",
            timestamp: now.addingTimeInterval(-31 * 24 * 60 * 60),
            duration: 1,
            modelID: "apple-speech"
        )
        try historyStore.save(expiredRecord)

        XCTAssertEqual(try historyStore.prune(now: now).map(\.id), [expiredRecord.id])

        let dataAfterPruning = try Data(contentsOf: learningURL)
        let storeAfterPruning = try JSONDecoder().decode(LocalLearningStore.self, from: dataAfterPruning)
        XCTAssertEqual(storeAfterPruning.learnedTerms.map(\.term), ["Kubernetes"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowLocalLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
