/// What a hotkey press should do while Voice Memo and Voice Rewrite use tap-to-latch.
public enum VoiceActionHotkeyDecision: Equatable, Sendable {
    /// Start the requested voice action and keep it recording until it is stopped.
    case start(RecordingActionKind)
    /// Stop the latched voice action and deliver its result.
    case stop(RecordingActionKind)
    /// Do nothing; another voice action owns the microphone.
    case ignore
    /// No voice action is latched, so the Dictation hotkey keeps its normal behavior.
    case passThrough
}

/// Voice Memo and Voice Rewrite latch on with one press of their chord. The latched
/// action stops when its own chord is pressed again or when the Dictation hotkey is tapped.
public enum VoiceActionLatchPolicy {
    /// Decides a press (not a key repeat or release) of a voice action chord.
    public static func voiceChordPressed(
        _ requested: RecordingActionKind,
        latched: RecordingActionKind?
    ) -> VoiceActionHotkeyDecision {
        guard requested != .dictation else { return .ignore }
        guard let latched else { return .start(requested) }
        return latched == requested ? .stop(requested) : .ignore
    }

    /// Decides the Dictation hotkey's start or toggle gesture.
    public static func dictationHotkeyPressed(latched: RecordingActionKind?) -> VoiceActionHotkeyDecision {
        guard let latched, latched != .dictation else { return .passThrough }
        return .stop(latched)
    }
}
