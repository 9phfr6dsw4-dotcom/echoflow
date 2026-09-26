import Speech
import XCTest

final class SpeechTranscriberPresetTests: XCTestCase {
    func testProgressivePresetPublishesFastVolatileResults() {
        let reportingOptions = SpeechTranscriber.Preset.progressiveTranscription.reportingOptions

        XCTAssertTrue(reportingOptions.contains(.fastResults))
        XCTAssertTrue(reportingOptions.contains(.volatileResults))
    }
}
