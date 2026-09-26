public enum RecordingActionKind: Equatable, Sendable {
    case dictation
    case voiceMemo
    case rewrite
}

public enum RecordingActionEventDecision: Equatable, Sendable {
    case cancelPendingStart
    case stopActiveRecording
    case ignore
}

public enum RecordingActionEventPolicy {
    public static func decision(
        requestedAction: RecordingActionKind,
        pendingAction: RecordingActionKind?,
        activeAction: RecordingActionKind
    ) -> RecordingActionEventDecision {
        if let pendingAction {
            return pendingAction == requestedAction ? .cancelPendingStart : .ignore
        }
        return activeAction == requestedAction ? .stopActiveRecording : .ignore
    }
}
