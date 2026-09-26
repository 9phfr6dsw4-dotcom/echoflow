import Foundation
import XCTest
@testable import EchoFlowCore

final class SmartLinkStoreTests: XCTestCase {
    func testPhraseExpansionIsCaseInsensitivePreservesPunctuationAndExpandsEveryOccurrence() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "my GitHub", destinationURL: "https://github.com/example")

        XCTAssertEqual(
            store.applying(to: "See MY GITHUB, then my GitHub!"),
            "See https://github.com/example, then https://github.com/example!"
        )
    }

    func testPhraseMustHaveWordBoundariesAndDoesNotMatchInsideLongerWords() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "my GitHub", destinationURL: "https://github.com/example")

        XCTAssertEqual(
            store.applying(to: "supermy GitHub and my GitHubish stay unchanged"),
            "supermy GitHub and my GitHubish stay unchanged"
        )
    }

    func testLongestPhraseWinsWhenSmartLinkPhrasesOverlap() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "GitHub", destinationURL: "https://github.com")
        _ = try store.add(phrase: "my GitHub", destinationURL: "https://github.com/example")

        XCTAssertEqual(
            store.applying(to: "my GitHub, then GitHub"),
            "https://github.com/example, then https://github.com"
        )
    }

    func testPhraseWhitespaceIsNormalizedAndMatchingAcceptsRepeatedWhitespace() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "  my   GitHub  ", destinationURL: "https://github.com/example")

        XCTAssertEqual(store.links.first?.phrase, "my GitHub")
        XCTAssertEqual(store.applying(to: "my   GitHub"), "https://github.com/example")
    }

    func testDuplicatePhraseIsRejectedCaseInsensitively() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "my GitHub", destinationURL: "https://github.com/example")

        XCTAssertThrowsError(try store.add(phrase: "MY GITHUB", destinationURL: "https://github.com/other")) {
            XCTAssertEqual($0 as? SmartLinkStoreError, .duplicatePhrase)
        }
    }

    func testOnlyAbsoluteHTTPAndHTTPSURLsWithoutCredentialsAreAccepted() {
        var store = SmartLinkStore()

        XCTAssertThrowsError(try store.add(phrase: "GitHub", destinationURL: "javascript:alert(1)"))
        XCTAssertThrowsError(try store.add(phrase: "GitHub", destinationURL: "ftp://example.com"))
        XCTAssertThrowsError(try store.add(phrase: "GitHub", destinationURL: "https://user:pass@example.com"))
        XCTAssertThrowsError(try store.add(phrase: "GitHub", destinationURL: "https:///missing-host"))
    }

    func testEditingOnlyPhrasePreservesExistingDestinationURL() {
        XCTAssertEqual(
            SmartLinkEditPolicy.values(
                existingPhrase: "my GitHub",
                existingDestinationURL: "https://github.com/example",
                phraseDraft: "my work GitHub",
                destinationURLDraft: nil
            ),
            SmartLinkEditValues(phrase: "my work GitHub", destinationURL: "https://github.com/example")
        )
    }

    func testEditingOnlyURLPreservesExistingPhrase() {
        XCTAssertEqual(
            SmartLinkEditPolicy.values(
                existingPhrase: "my GitHub",
                existingDestinationURL: "https://github.com/example",
                phraseDraft: nil,
                destinationURLDraft: "https://github.com/new"
            ),
            SmartLinkEditValues(phrase: "my GitHub", destinationURL: "https://github.com/new")
        )
    }

    func testEditingBothFieldsUsesBothDraftValues() {
        XCTAssertEqual(
            SmartLinkEditPolicy.values(
                existingPhrase: "my GitHub",
                existingDestinationURL: "https://github.com/example",
                phraseDraft: "my work GitHub",
                destinationURLDraft: "https://github.com/new"
            ),
            SmartLinkEditValues(phrase: "my work GitHub", destinationURL: "https://github.com/new")
        )
    }

    func testEditingKeepsIdentityAndRejectsConflictingPhrases() throws {
        var store = SmartLinkStore()
        let first = try store.add(phrase: "GitHub", destinationURL: "https://github.com")
        _ = try store.add(phrase: "My site", destinationURL: "https://example.com")

        let edited = try store.edit(id: first.id, phrase: "GitHub profile", destinationURL: "https://github.com/example")

        XCTAssertEqual(edited.id, first.id)
        XCTAssertEqual(edited.phrase, "GitHub profile")
        XCTAssertThrowsError(try store.edit(id: first.id, phrase: "My site", destinationURL: "https://github.com/example")) {
            XCTAssertEqual($0 as? SmartLinkStoreError, .duplicatePhrase)
        }
    }

    func testCodableRoundTripPreservesSmartLinks() throws {
        var store = SmartLinkStore()
        _ = try store.add(phrase: "my GitHub", destinationURL: "https://github.com/example")

        let decoded = try JSONDecoder().decode(SmartLinkStore.self, from: JSONEncoder().encode(store))

        XCTAssertEqual(decoded, store)
    }
}
