import Foundation
import XCTest
@testable import EchoFlowCore

final class BatchOneSettingsPolicyTests: XCTestCase {
    func testLaunchAtLoginDefaultsOnButRespectsAnExplicitSavedChoice() {
        XCTAssertTrue(LaunchAtLoginPreferencePolicy.isEnabled(storedValue: nil))
        XCTAssertTrue(LaunchAtLoginPreferencePolicy.isEnabled(storedValue: true))
        XCTAssertFalse(LaunchAtLoginPreferencePolicy.isEnabled(storedValue: false))
    }

    func testRecordingSoundVolumeDefaultsToHalfAndClampsInvalidValues() {
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: nil), 0.5)
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: 0.3), 0.3, accuracy: 0.0001)
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: -2), 0)
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: 2), 1)
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: .nan), 0.5)
        XCTAssertEqual(RecordingSoundVolumePolicy.normalizedLevel(storedValue: .infinity), 0.5)
    }

    func testSystemAggregateNamesAreHiddenButUserAggregatesRemainAvailable() {
        XCTAssertFalse(MicrophoneDeviceVisibilityPolicy.shouldShow(
            name: "CADefaultDeviceAggregate",
            uid: "aggregate-uid"
        ))
        XCTAssertFalse(MicrophoneDeviceVisibilityPolicy.shouldShow(
            name: "Default Input",
            uid: "CADefaultDeviceAggregate"
        ))
        XCTAssertTrue(MicrophoneDeviceVisibilityPolicy.shouldShow(
            name: "My Aggregate Input",
            uid: "com.example.user-aggregate"
        ))
    }

    func testPhysicalAndVirtualNonAggregateInputsRemainVisible() {
        XCTAssertTrue(MicrophoneDeviceVisibilityPolicy.shouldShow(
            name: "MacBook Pro Microphone",
            uid: "built-in-input"
        ))
        XCTAssertTrue(MicrophoneDeviceVisibilityPolicy.shouldShow(
            name: "USB Microphone",
            uid: "usb-input"
        ))
    }
}
