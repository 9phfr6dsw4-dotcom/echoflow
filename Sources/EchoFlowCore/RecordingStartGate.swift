/// Invalidates a pending hotkey recording start if the key is released before setup finishes.
public struct RecordingStartGate: Sendable {
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?

    public init() {}

    /// Returns nil while an earlier start request is still unwinding.
    public mutating func begin() -> UInt64? {
        guard activeGeneration == nil else { return nil }
        generation &+= 1
        activeGeneration = generation
        return generation
    }

    public func isCurrent(_ token: UInt64) -> Bool {
        activeGeneration == token && generation == token
    }

    /// Invalidates the active request but keeps it reserved until `finish(_:)`.
    @discardableResult
    public mutating func cancelPending() -> Bool {
        guard activeGeneration != nil else { return false }
        generation &+= 1
        return true
    }

    public mutating func finish(_ token: UInt64) {
        guard activeGeneration == token else { return }
        activeGeneration = nil
    }
}

public enum RecordingCaptureStartPolicy {
    public static func canCapture(startIsCurrent: Bool, targetIsExcluded: Bool) -> Bool {
        startIsCurrent && !targetIsExcluded
    }

    public static func canStartEngine(startIsCurrent: Bool, microphoneAuthorized: Bool) -> Bool {
        startIsCurrent && microphoneAuthorized
    }
}
