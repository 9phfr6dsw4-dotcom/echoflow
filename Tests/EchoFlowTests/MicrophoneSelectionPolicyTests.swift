import XCTest
import EchoFlowCore

final class MicrophoneSelectionPolicyTests: XCTestCase {
    func testAutomaticSelectionFollowsConfiguredPriorityOrder() {
        let first = MicrophoneDevice(id: "first", name: "First")
        let second = MicrophoneDevice(id: "second", name: "Second")
        let policy = MicrophoneSelectionPolicy(
            discoveredDevices: [first, second],
            priorityDeviceIDs: ["second", "first"]
        )

        XCTAssertEqual(policy.currentReadyDevice, second)
    }

    func testPriorityCanBeReordered() {
        let first = MicrophoneDevice(id: "first", name: "First")
        let second = MicrophoneDevice(id: "second", name: "Second")
        var policy = MicrophoneSelectionPolicy(discoveredDevices: [first, second])

        policy.setPriorityOrder(["second", "first"])

        XCTAssertEqual(policy.priorityDeviceIDs, ["second", "first"])
        XCTAssertEqual(policy.currentReadyDevice, second)
    }

    func testNewlyDiscoveredDevicesAreAppendedAfterExistingPriorityOrder() {
        let first = MicrophoneDevice(id: "first", name: "First")
        let second = MicrophoneDevice(id: "second", name: "Second")
        let third = MicrophoneDevice(id: "third", name: "Third")
        var policy = MicrophoneSelectionPolicy(
            discoveredDevices: [first, second],
            priorityDeviceIDs: ["second", "first"]
        )

        policy.reconcile(discoveredDevices: [third, first, second])

        XCTAssertEqual(policy.priorityDeviceIDs, ["second", "first", "third"])
    }

    func testMissingPreferredDeviceFallsBackToFirstAllowedPriorityDevice() {
        let first = MicrophoneDevice(id: "first", name: "First")
        let second = MicrophoneDevice(id: "second", name: "Second")
        var policy = MicrophoneSelectionPolicy(
            discoveredDevices: [first, second],
            priorityDeviceIDs: ["second", "first"],
            preferredDeviceID: "first"
        )

        policy.reconcile(discoveredDevices: [second])

        XCTAssertEqual(policy.preferredDeviceID, "first")
        XCTAssertEqual(policy.currentReadyDevice, second)
    }

    func testUnavailablePreferredDeviceFallsBackAndNoReadyDeviceResolvesToNone() {
        let unavailable = MicrophoneDevice(id: "unavailable", name: "Unavailable", isAvailable: false)
        let available = MicrophoneDevice(id: "available", name: "Available")
        var policy = MicrophoneSelectionPolicy(
            discoveredDevices: [unavailable, available],
            priorityDeviceIDs: ["unavailable", "available"],
            preferredDeviceID: "unavailable"
        )

        XCTAssertEqual(policy.currentReadyDevice, available)

        policy.reconcile(discoveredDevices: [unavailable, available.withAvailability(false)])

        XCTAssertNil(policy.currentReadyDevice)
    }

    func testClosedLidSkipsPreferredBuiltInMacBookMicrophone() {
        let builtIn = MicrophoneDevice(
            id: "built-in",
            name: "MacBook Microphone",
            isBuiltInMacBookMicrophone: true
        )
        let external = MicrophoneDevice(id: "external", name: "External")
        let policy = MicrophoneSelectionPolicy(
            discoveredDevices: [builtIn, external],
            priorityDeviceIDs: ["built-in", "external"],
            preferredDeviceID: "built-in",
            isLidClosed: true
        )

        XCTAssertEqual(policy.currentReadyDevice, external)
    }

    func testDirectSelectionOverridesAutomaticPriorityWhenDeviceIsReady() {
        let first = MicrophoneDevice(id: "first", name: "First")
        let second = MicrophoneDevice(id: "second", name: "Second")
        var policy = MicrophoneSelectionPolicy(discoveredDevices: [first, second])

        XCTAssertTrue(policy.selectDevice(id: "second"))
        XCTAssertEqual(policy.currentReadyDevice, second)
    }
}

private extension MicrophoneDevice {
    func withAvailability(_ isAvailable: Bool) -> MicrophoneDevice {
        MicrophoneDevice(
            id: id,
            name: name,
            isBuiltInMacBookMicrophone: isBuiltInMacBookMicrophone,
            isAvailable: isAvailable
        )
    }
}
