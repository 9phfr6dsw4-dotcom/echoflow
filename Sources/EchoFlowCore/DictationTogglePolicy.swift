import Foundation

public enum DictationTogglePolicy {
    public static func canStopHoldRecording(isHoldRecordingActive: Bool) -> Bool {
        isHoldRecordingActive
    }

    public static func canToggleDictation(
        isRecording: Bool,
        activeRecordingIsDictation: Bool,
        hasPendingRecordingStart: Bool,
        pendingRecordingStartIsDictation: Bool
    ) -> Bool {
        if hasPendingRecordingStart && !pendingRecordingStartIsDictation { return false }
        if isRecording && !activeRecordingIsDictation { return false }
        return true
    }
}
