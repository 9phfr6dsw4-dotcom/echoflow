import XCTest
@testable import EchoFlowCore

final class DictationTogglePolicyTests: XCTestCase {
    func testRejectedHoldStartCannotStopAnExistingRecordingOnKeyUp() {
        XCTAssertFalse(DictationTogglePolicy.canStopHoldRecording(isHoldRecordingActive: false))
        XCTAssertTrue(DictationTogglePolicy.canStopHoldRecording(isHoldRecordingActive: true))
    }

    func testDictationToggleCannotStopAnActiveVoiceAction() {
        XCTAssertFalse(DictationTogglePolicy.canToggleDictation(
            isRecording: true,
            activeRecordingIsDictation: false,
            hasPendingRecordingStart: false,
            pendingRecordingStartIsDictation: false
        ))
    }

    func testDictationToggleCannotCancelAPendingVoiceAction() {
        XCTAssertFalse(DictationTogglePolicy.canToggleDictation(
            isRecording: false,
            activeRecordingIsDictation: false,
            hasPendingRecordingStart: true,
            pendingRecordingStartIsDictation: false
        ))
    }

    func testDictationToggleCanCancelItsOwnPendingStart() {
        XCTAssertTrue(DictationTogglePolicy.canToggleDictation(
            isRecording: false,
            activeRecordingIsDictation: false,
            hasPendingRecordingStart: true,
            pendingRecordingStartIsDictation: true
        ))
    }

    func testDictationToggleCanStopItsOwnRecording() {
        XCTAssertTrue(DictationTogglePolicy.canToggleDictation(
            isRecording: true,
            activeRecordingIsDictation: true,
            hasPendingRecordingStart: false,
            pendingRecordingStartIsDictation: false
        ))
    }

    func testDictationToggleCanStartWhenNoOtherActionIsActive() {
        XCTAssertTrue(DictationTogglePolicy.canToggleDictation(
            isRecording: false,
            activeRecordingIsDictation: false,
            hasPendingRecordingStart: false,
            pendingRecordingStartIsDictation: false
        ))
    }
}
