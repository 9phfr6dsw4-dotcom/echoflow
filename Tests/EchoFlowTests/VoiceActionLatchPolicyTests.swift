import XCTest
@testable import EchoFlowCore

final class VoiceActionLatchPolicyTests: XCTestCase {
    func testChordPressStartsItsActionWhenNothingIsLatched() {
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.voiceMemo, latched: nil), .start(.voiceMemo))
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.rewrite, latched: nil), .start(.rewrite))
    }

    func testPressingTheSameChordAgainStopsTheLatchedAction() {
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.voiceMemo, latched: .voiceMemo), .stop(.voiceMemo))
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.rewrite, latched: .rewrite), .stop(.rewrite))
    }

    func testTheOtherVoiceChordCannotInterruptALatchedAction() {
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.rewrite, latched: .voiceMemo), .ignore)
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.voiceMemo, latched: .rewrite), .ignore)
    }

    func testDictationIsNeverStartedThroughAVoiceChord() {
        XCTAssertEqual(VoiceActionLatchPolicy.voiceChordPressed(.dictation, latched: nil), .ignore)
    }

    func testDictationHotkeyStopsALatchedVoiceAction() {
        XCTAssertEqual(VoiceActionLatchPolicy.dictationHotkeyPressed(latched: .voiceMemo), .stop(.voiceMemo))
        XCTAssertEqual(VoiceActionLatchPolicy.dictationHotkeyPressed(latched: .rewrite), .stop(.rewrite))
    }

    func testDictationHotkeyKeepsItsNormalBehaviorWhenNothingIsLatched() {
        XCTAssertEqual(VoiceActionLatchPolicy.dictationHotkeyPressed(latched: nil), .passThrough)
        XCTAssertEqual(VoiceActionLatchPolicy.dictationHotkeyPressed(latched: .dictation), .passThrough)
    }
}
