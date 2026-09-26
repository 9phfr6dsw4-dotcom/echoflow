import Foundation

public struct MicrophoneDevice: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isBuiltInMacBookMicrophone: Bool
    public let isAvailable: Bool

    public init(
        id: String,
        name: String,
        isBuiltInMacBookMicrophone: Bool = false,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isBuiltInMacBookMicrophone = isBuiltInMacBookMicrophone
        self.isAvailable = isAvailable
    }
}

public struct MicrophoneSelectionPolicy: Equatable, Sendable {
    private var devicesByID: [String: MicrophoneDevice]

    public private(set) var priorityDeviceIDs: [String]
    public private(set) var preferredDeviceID: String?
    public private(set) var isLidClosed: Bool

    public init(
        discoveredDevices: [MicrophoneDevice],
        priorityDeviceIDs: [String]? = nil,
        preferredDeviceID: String? = nil,
        isLidClosed: Bool = false
    ) {
        let devices = Self.uniqueDevices(discoveredDevices)
        let validIDs = Set(devices.map(\.id))
        let requestedOrder = priorityDeviceIDs ?? devices.map(\.id)

        self.devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.priorityDeviceIDs = Self.orderedIDs(
            preferredIDs: requestedOrder,
            remainingIDs: devices.map(\.id),
            validIDs: validIDs
        )
        self.preferredDeviceID = preferredDeviceID
        self.isLidClosed = isLidClosed
    }

    /// The preferred device wins when ready; otherwise the first ready device in priority order.
    public var currentReadyDevice: MicrophoneDevice? {
        if let preferredDeviceID,
           let preferredDevice = devicesByID[preferredDeviceID],
           isAllowed(preferredDevice) {
            return preferredDevice
        }

        return priorityDeviceIDs
            .compactMap { devicesByID[$0] }
            .first(where: isAllowed)
    }

    /// Reorders known devices and keeps any omitted devices in their existing relative order.
    public mutating func setPriorityOrder(_ orderedIDs: [String]) {
        priorityDeviceIDs = Self.orderedIDs(
            preferredIDs: orderedIDs,
            remainingIDs: priorityDeviceIDs,
            validIDs: Set(devicesByID.keys)
        )
    }

    /// Refreshes device snapshots, retaining surviving priorities and appending new devices.
    public mutating func reconcile(discoveredDevices: [MicrophoneDevice]) {
        let devices = Self.uniqueDevices(discoveredDevices)
        let validIDs = Set(devices.map(\.id))
        let survivingIDs = priorityDeviceIDs.filter { validIDs.contains($0) }
        let survivingIDSet = Set(survivingIDs)
        let newIDs = devices.map(\.id).filter { !survivingIDSet.contains($0) }

        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        priorityDeviceIDs = Self.orderedIDs(
            preferredIDs: survivingIDs,
            remainingIDs: newIDs,
            validIDs: validIDs
        )
    }

    /// Direct selection is accepted only for a currently ready, allowed device.
    @discardableResult
    public mutating func selectDevice(id: String) -> Bool {
        guard let device = devicesByID[id], isAllowed(device) else { return false }
        preferredDeviceID = id
        return true
    }

    /// Lid state is supplied by the app layer; this policy does not detect it.
    public mutating func setLidClosed(_ isClosed: Bool) {
        isLidClosed = isClosed
    }

    private func isAllowed(_ device: MicrophoneDevice) -> Bool {
        device.isAvailable && !(isLidClosed && device.isBuiltInMacBookMicrophone)
    }

    private static func uniqueDevices(_ devices: [MicrophoneDevice]) -> [MicrophoneDevice] {
        var seenIDs = Set<String>()
        return devices.filter { seenIDs.insert($0.id).inserted }
    }

    private static func orderedIDs(
        preferredIDs: [String],
        remainingIDs: [String],
        validIDs: Set<String>
    ) -> [String] {
        var seenIDs = Set<String>()
        return (preferredIDs + remainingIDs).filter { id in
            validIDs.contains(id) && seenIDs.insert(id).inserted
        }
    }
}
