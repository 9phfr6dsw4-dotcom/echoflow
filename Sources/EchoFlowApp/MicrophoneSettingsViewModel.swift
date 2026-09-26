import AudioToolbox
import AVFoundation
import CoreAudio
import EchoFlowCore
import Foundation
import IOKit
import Observation
import SwiftUI

@MainActor
@Observable
final class MicrophoneSettingsViewModel {
    private(set) var devices: [MicrophoneDevice] = []
    private(set) var priorityDeviceIDs: [String] = []
    private(set) var preferredDeviceID: String?
    private(set) var currentReadyDevice: MicrophoneDevice?
    private(set) var isLidClosed = false
    var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var audioDeviceIDsByUID: [String: AudioDeviceID] = [:]
    @ObservationIgnored private var policy = MicrophoneSelectionPolicy(discoveredDevices: [])

    private static let priorityDefaultsKey = "EchoFlow.microphonePriority"
    private static let preferredDefaultsKey = "EchoFlow.preferredMicrophone"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.preferredDeviceID = defaults.string(forKey: Self.preferredDefaultsKey)
        refreshDevices()
    }

    var orderedDevices: [MicrophoneDevice] {
        let lookup = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        return priorityDeviceIDs.compactMap { lookup[$0] }
    }

    var pickerSelection: String {
        guard let preferredDeviceID, devices.contains(where: { $0.id == preferredDeviceID }) else {
            return Self.automaticSelection
        }
        return preferredDeviceID
    }

    static let automaticSelection = "__echoflow_automatic_microphone__"

    func setPickerSelection(_ id: String) {
        if id == Self.automaticSelection {
            preferredDeviceID = nil
        } else {
            guard policy.selectDevice(id: id) else {
                errorMessage = "That microphone is not currently ready."
                return
            }
            preferredDeviceID = id
        }
        defaults.set(preferredDeviceID, forKey: Self.preferredDefaultsKey)
        updatePolicySnapshot()
    }

    func movePriority(id: String, direction: Int) {
        guard let currentIndex = priorityDeviceIDs.firstIndex(of: id) else { return }
        let destination = currentIndex + direction
        guard priorityDeviceIDs.indices.contains(destination) else { return }
        var updatedIDs = priorityDeviceIDs
        updatedIDs.swapAt(currentIndex, destination)
        policy.setPriorityOrder(updatedIDs)
        priorityDeviceIDs = policy.priorityDeviceIDs
        defaults.set(priorityDeviceIDs, forKey: Self.priorityDefaultsKey)
        updateCurrentDevice()
    }

    func refreshDevices() {
        isLidClosed = AudioInputDeviceCatalog.isLidClosed()
        let found = AudioInputDeviceCatalog.inputDevices()
        audioDeviceIDsByUID = Dictionary(uniqueKeysWithValues: found.map { ($0.uid, $0.audioDeviceID) })

        var discovered = found.map(\.microphone)
        if defaults.stringArray(forKey: Self.priorityDefaultsKey)?.isEmpty ?? true,
           let defaultID = AudioInputDeviceCatalog.defaultInputDeviceID(),
           let defaultDevice = found.first(where: { $0.audioDeviceID == defaultID }) {
            discovered.removeAll { $0.id == defaultDevice.uid }
            discovered.insert(defaultDevice.microphone, at: 0)
        }

        policy = MicrophoneSelectionPolicy(
            discoveredDevices: discovered,
            priorityDeviceIDs: defaults.stringArray(forKey: Self.priorityDefaultsKey),
            preferredDeviceID: preferredDeviceID,
            isLidClosed: isLidClosed
        )
        devices = discovered
        priorityDeviceIDs = policy.priorityDeviceIDs
        defaults.set(priorityDeviceIDs, forKey: Self.priorityDefaultsKey)
        updateCurrentDevice()
        errorMessage = nil
    }

    func configure(inputNode: AVAudioInputNode) throws -> String {
        refreshDevices()
        guard let device = policy.currentReadyDevice,
              let audioDeviceID = audioDeviceIDsByUID[device.id] else {
            throw MicrophoneSelectionError.noReadyInput
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw MicrophoneSelectionError.audioUnitUnavailable
        }
        var selectedDeviceID = audioDeviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicrophoneSelectionError.couldNotSelectDevice(device.name, status)
        }
        currentReadyDevice = device
        return device.name
    }

    private func updatePolicySnapshot() {
        policy = MicrophoneSelectionPolicy(
            discoveredDevices: devices,
            priorityDeviceIDs: priorityDeviceIDs,
            preferredDeviceID: preferredDeviceID,
            isLidClosed: isLidClosed
        )
        updateCurrentDevice()
    }

    private func updateCurrentDevice() {
        currentReadyDevice = policy.currentReadyDevice
    }
}

private enum MicrophoneSelectionError: LocalizedError {
    case noReadyInput
    case audioUnitUnavailable
    case couldNotSelectDevice(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noReadyInput:
            "No permitted microphone is currently available. Connect a microphone or choose another device in Settings."
        case .audioUnitUnavailable:
            "macOS did not provide an audio input unit for the selected microphone."
        case .couldNotSelectDevice(let name, let status):
            "Could not select \(name) as the input microphone (Audio Unit status \(status))."
        }
    }
}

private enum AudioInputDeviceCatalog {
    struct Device {
        let uid: String
        let microphone: MicrophoneDevice
        let audioDeviceID: AudioDeviceID
    }

    static func inputDevices() -> [Device] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var audioIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = audioIDs.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareBadObjectError }
            return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, baseAddress)
        }
        guard status == noErr else { return [] }

        return audioIDs.compactMap { audioDeviceID in
            guard hasInputChannels(audioDeviceID),
                  let uid = stringProperty(audioDeviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(audioDeviceID, selector: kAudioObjectPropertyName) else { return nil }
            let transport = transportType(audioDeviceID)
            guard MicrophoneDeviceVisibilityPolicy.shouldShow(name: name, uid: uid) else { return nil }
            let builtInMac = transport == kAudioDeviceTransportTypeBuiltIn
                && name.localizedCaseInsensitiveContains("MacBook")
            let microphone = MicrophoneDevice(
                id: uid,
                name: name,
                isBuiltInMacBookMicrophone: builtInMac,
                isAvailable: true
            )
            return Device(uid: uid, microphone: microphone, audioDeviceID: audioDeviceID)
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return false }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio returns a retained CFString that the caller must release.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
