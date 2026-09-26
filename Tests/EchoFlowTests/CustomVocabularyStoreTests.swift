import Foundation
import XCTest
@testable import EchoFlowCore

final class CustomVocabularyStoreTests: XCTestCase {
    func testAddingNormalizesWhitespaceAndDeduplicatesWithoutChangingIdentity() throws {
        var store = CustomVocabularyStore()

        let first = try store.addTerm("  Acme   Labs  ")
        let duplicate = try store.addTerm("acme labs")

        XCTAssertEqual(first.term, "Acme Labs")
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(store.terms, [first])
    }

    func testEditingPreservesIdentityAndRejectsAnotherTermDuplicate() throws {
        var store = CustomVocabularyStore()
        let edited = try store.addTerm("Echo Flow")
        _ = try store.addTerm("Acme Labs")

        let result = try store.editTerm(id: edited.id, to: "  Echo   Flow Pro ")

        XCTAssertEqual(result.id, edited.id)
        XCTAssertEqual(result.term, "Echo Flow Pro")
        XCTAssertThrowsError(try store.editTerm(id: edited.id, to: " acme   labs ")) { error in
            XCTAssertEqual(error as? CustomVocabularyStoreError, .duplicateTerm)
        }
        XCTAssertEqual(store.terms.first(where: { $0.id == edited.id })?.term, "Echo Flow Pro")
    }

    func testRemovingTermByStableIdentity() throws {
        var store = CustomVocabularyStore()
        let term = try store.addTerm("Kubernetes")

        XCTAssertTrue(store.removeTerm(id: term.id))
        XCTAssertTrue(store.terms.isEmpty)
        XCTAssertFalse(store.removeTerm(id: term.id))
    }

    func testRejectsBlankControlOnlyAndOverlongTerms() {
        var store = CustomVocabularyStore()

        XCTAssertThrowsError(try store.addTerm(" \t  \n ")) { error in
            XCTAssertEqual(error as? CustomVocabularyStoreError, .invalidTerm)
        }
        XCTAssertThrowsError(try store.addTerm("\u{0000}\u{0007}")) { error in
            XCTAssertEqual(error as? CustomVocabularyStoreError, .invalidTerm)
        }
        XCTAssertThrowsError(
            try store.addTerm(String(repeating: "a", count: CustomVocabularyStore.maximumTermLength + 1))
        ) { error in
            XCTAssertEqual(
                error as? CustomVocabularyStoreError,
                .termTooLong(maximumLength: CustomVocabularyStore.maximumTermLength)
            )
        }
    }

    func testCodableRoundTripPreservesTermsAndStableIdentities() throws {
        var store = CustomVocabularyStore()
        let first = try store.addTerm("Kubernetes")
        let second = try store.addTerm("Acme Labs")
        _ = try store.editTerm(id: first.id, to: "Kubernetes Cloud")

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(CustomVocabularyStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.terms.map(\.id), store.terms.map(\.id))
        XCTAssertTrue(decoded.terms.contains(where: { $0.id == second.id }))
    }

    func testTermOrderingDoesNotDependOnInsertionOrder() throws {
        var firstStore = CustomVocabularyStore()
        _ = try firstStore.addTerm("Zebra Labs")
        _ = try firstStore.addTerm("acme")
        _ = try firstStore.addTerm("Echo Flow")

        var secondStore = CustomVocabularyStore()
        _ = try secondStore.addTerm("Echo Flow")
        _ = try secondStore.addTerm("Zebra Labs")
        _ = try secondStore.addTerm("acme")

        XCTAssertEqual(firstStore.terms.map(\.term), ["acme", "Echo Flow", "Zebra Labs"])
        XCTAssertEqual(secondStore.terms.map(\.term), firstStore.terms.map(\.term))
    }
}
