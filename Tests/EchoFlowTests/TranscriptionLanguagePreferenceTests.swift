import XCTest
@testable import EchoFlowCore

final class TranscriptionLanguagePreferenceTests: XCTestCase {
    func testEmptyOrWhitespacePreferenceUsesTheSystemLanguage() {
        XCTAssertEqual(
            TranscriptionLanguagePreference.resolve("", systemLanguageIdentifier: "en-US"),
            "en-US"
        )
        XCTAssertEqual(
            TranscriptionLanguagePreference.resolve("  ", systemLanguageIdentifier: "fr-CA"),
            "fr-CA"
        )
        XCTAssertEqual(
            TranscriptionLanguagePreference.resolve(nil, systemLanguageIdentifier: "de-DE"),
            "de-DE"
        )
    }

    func testPinnedLanguageOverridesTheSystemLanguage() {
        XCTAssertEqual(
            TranscriptionLanguagePreference.resolve("es", systemLanguageIdentifier: "en-US"),
            "es"
        )
    }
}
