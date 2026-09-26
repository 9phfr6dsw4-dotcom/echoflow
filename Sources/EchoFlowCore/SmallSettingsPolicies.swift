import Foundation

public enum LaunchAtLoginPreferencePolicy {
    /// The first launch opts in; an explicit user choice is always preserved.
    public static func isEnabled(storedValue: Bool?) -> Bool {
        storedValue ?? true
    }
}

public enum RecordingSoundVolumePolicy {
    public static let defaultLevel = 0.5

    public static func normalizedLevel(storedValue: Double?) -> Double {
        guard let storedValue, storedValue.isFinite else { return defaultLevel }
        return min(max(storedValue, 0), 1)
    }
}

public enum MicrophoneDeviceVisibilityPolicy {
    private static let systemAggregateMarker = "CADefaultDeviceAggregate"

    public static func shouldShow(name: String, uid: String) -> Bool {
        !name.localizedCaseInsensitiveContains(systemAggregateMarker)
            && !uid.localizedCaseInsensitiveContains(systemAggregateMarker)
    }
}
