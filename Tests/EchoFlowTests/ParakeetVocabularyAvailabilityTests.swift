import XCTest
@testable import EchoFlowCore

final class ParakeetVocabularyAvailabilityTests: XCTestCase {
    func testNoTermsUsesBaseParakeetDecodeWithoutCompanionOrTimings() {
        XCTAssertFalse(ParakeetVocabularyAvailability.canApplyCustomTerms(
            hasTerms: false,
            companionInstalled: false,
            hasTokenTimings: false
        ))
    }

    func testMissingCompanionKeepsBaseDecodeAvailable() {
        XCTAssertFalse(ParakeetVocabularyAvailability.canApplyCustomTerms(
            hasTerms: true,
            companionInstalled: false,
            hasTokenTimings: true
        ))
    }

    func testMissingTimingsKeepsBaseDecodeAvailable() {
        XCTAssertFalse(ParakeetVocabularyAvailability.canApplyCustomTerms(
            hasTerms: true,
            companionInstalled: true,
            hasTokenTimings: false
        ))
    }

    func testAppliesCustomTermsOnlyWhenAllRescoringInputsExist() {
        XCTAssertTrue(ParakeetVocabularyAvailability.canApplyCustomTerms(
            hasTerms: true,
            companionInstalled: true,
            hasTokenTimings: true
        ))
    }
}
