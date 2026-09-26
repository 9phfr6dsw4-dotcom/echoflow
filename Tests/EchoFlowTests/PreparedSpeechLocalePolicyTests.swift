import XCTest
@testable import EchoFlowCore

final class PreparedSpeechLocalePolicyTests: XCTestCase {
    func testPreparedLocaleIsReusableForSamePinnedLanguageWhenAssetsAreInstalled() {
        XCTAssertTrue(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: "en-US",
            requestedIdentifier: "en",
            assetsInstalled: true
        ))
    }

    func testPreparedLocaleIsNotReusableWhenSystemAssetsAreMissing() {
        XCTAssertFalse(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: "en-US",
            requestedIdentifier: "en-US",
            assetsInstalled: false
        ))
    }

    func testDifferentOrMissingPreparedLanguageRequiresPreparation() {
        XCTAssertFalse(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: "fr-FR",
            requestedIdentifier: "de",
            assetsInstalled: true
        ))
        XCTAssertFalse(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: nil,
            requestedIdentifier: "en-US",
            assetsInstalled: true
        ))
    }

    func testScriptVariantsRequireSeparatePreparation() {
        XCTAssertFalse(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: "zh-Hans-CN",
            requestedIdentifier: "zh-Hant-TW",
            assetsInstalled: true
        ))
        XCTAssertTrue(PreparedSpeechLocalePolicy.isPrepared(
            preparedIdentifier: "zh-Hans-CN",
            requestedIdentifier: "zh-Hans-SG",
            assetsInstalled: true
        ))
    }
}
