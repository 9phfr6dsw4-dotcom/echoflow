import Foundation
import XCTest
@testable import EchoFlowCore

final class GlobalHotkeyStatusPolicyTests: XCTestCase {
    func testListenerDefaultsOnAndRemembersExplicitEnableOrDisable() {
        XCTAssertTrue(GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: true,
            previouslyEnabled: nil
        ))
        XCTAssertTrue(GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: true,
            previouslyEnabled: true
        ))
        XCTAssertFalse(GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: false,
            previouslyEnabled: nil
        ))
        XCTAssertFalse(GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: false,
            previouslyEnabled: true
        ))
        XCTAssertFalse(GlobalHotkeyStatusPolicy.shouldActivateListener(
            accessibilityGranted: true,
            previouslyEnabled: false
        ))
    }

    func testHotkeyPreferencePersistsEnabledAndDisabledChoices() throws {
        let suiteName = "GlobalHotkeyStatusPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(GlobalHotkeyStatusPolicy.storedEnabledPreference(in: defaults))
        GlobalHotkeyStatusPolicy.setEnabledPreference(true, in: defaults)
        XCTAssertEqual(GlobalHotkeyStatusPolicy.storedEnabledPreference(in: defaults), true)
        GlobalHotkeyStatusPolicy.setEnabledPreference(false, in: defaults)
        XCTAssertEqual(GlobalHotkeyStatusPolicy.storedEnabledPreference(in: defaults), false)
    }

    func testPermissionLossStopsOnlyAnActiveHoldRecording() {
        XCTAssertTrue(GlobalHotkeyStatusPolicy.shouldStopHoldRecording(
            accessibilityGranted: false,
            holdRecordingActive: true
        ))
        XCTAssertFalse(GlobalHotkeyStatusPolicy.shouldStopHoldRecording(
            accessibilityGranted: false,
            holdRecordingActive: false
        ))
        XCTAssertFalse(GlobalHotkeyStatusPolicy.shouldStopHoldRecording(
            accessibilityGranted: true,
            holdRecordingActive: true
        ))
    }

    func testStatusExplainsMissingAccessibilityPermission() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: false,
            hotkeyEnabledPreference: false,
            globalMonitorInstalled: false,
            receivedEventCount: 0,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: nil,
            lastRecognizedAction: nil
        )

        XCTAssertTrue(message.contains("Accessibility"))
        XCTAssertTrue(message.contains("Input Monitoring is not required"))
    }

    func testStatusReportsThatHotkeyWasNotEnabled() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: true,
            hotkeyEnabledPreference: false,
            globalMonitorInstalled: false,
            receivedEventCount: 0,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: nil,
            lastRecognizedAction: nil
        )

        XCTAssertTrue(message.contains("Hotkey is off"))
        XCTAssertTrue(message.contains("remembers this choice"))
    }

    func testStatusReportsGlobalListenerRegistrationFailure() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: true,
            hotkeyEnabledPreference: true,
            globalMonitorInstalled: false,
            receivedEventCount: 0,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: nil,
            lastRecognizedAction: nil
        )

        XCTAssertTrue(message.contains("system-wide keyboard listener"))
        XCTAssertTrue(message.contains("did not start"))
        XCTAssertTrue(message.contains("Enable Hotkey to retry"))
    }

    func testStatusShowsListenerWaitingForFirstKeyEvent() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: true,
            hotkeyEnabledPreference: true,
            globalMonitorInstalled: true,
            receivedEventCount: 0,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: nil,
            lastRecognizedAction: nil
        )

        XCTAssertTrue(message.contains("Listener active for Left Control tap-to-toggle"))
        XCTAssertTrue(message.contains("no keyboard events received yet"))
        XCTAssertTrue(message.contains("another app"))
    }

    func testStatusReportsReceivedEventsAndRecognizedHotkey() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: true,
            hotkeyEnabledPreference: true,
            globalMonitorInstalled: true,
            receivedEventCount: 4,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: "flagsChanged keyCode 59 from another app",
            lastRecognizedAction: "toggle dictation"
        )

        XCTAssertTrue(message.contains("Listener active for Left Control tap-to-toggle; received 4 keyboard events"))
        XCTAssertTrue(message.contains("flagsChanged keyCode 59 from another app"))
        XCTAssertTrue(message.contains("Recognized hotkey: toggle dictation"))
    }

    func testStatusDoesNotClaimRecognitionForUnmatchedKeys() {
        let message = GlobalHotkeyStatusPolicy.message(
            accessibilityGranted: true,
            hotkeyEnabledPreference: true,
            globalMonitorInstalled: true,
            receivedEventCount: 1,
            configuredHotkey: "Left Control tap-to-toggle",
            lastEventDescription: "keyDown keyCode 8 from another app",
            lastRecognizedAction: nil
        )

        XCTAssertTrue(message.contains("Listener active for Left Control tap-to-toggle; received 1 keyboard event"))
        XCTAssertTrue(message.contains("No configured hotkey has been recognized"))
    }
}
