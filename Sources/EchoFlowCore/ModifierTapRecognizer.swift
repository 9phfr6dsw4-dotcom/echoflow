import Foundation

public enum ModifierHotkeyMode: String, Codable, Hashable, Sendable {
    case tapToToggle
    case holdToTalk
}

public enum ModifierHotkeyEvent: Equatable, Sendable {
    case modifierChanged(isDown: Bool, hasOtherModifiers: Bool)
    case otherKeyDown
}

public enum ModifierHotkeyAction: Equatable, Sendable {
    case toggleRecording
    case startRecording
    case stopRecording
}

/// Recognizes tap-to-toggle and hold-to-talk gestures without treating modifier chords as dictation shortcuts.
public struct ModifierTapRecognizer: Sendable {
    private let mode: ModifierHotkeyMode
    private var isPressed = false
    private var chordInterruptedTap = false
    private var holdRecordingActive = false

    public init(mode: ModifierHotkeyMode = .tapToToggle) {
        self.mode = mode
    }

    public mutating func consume(_ event: ModifierHotkeyEvent) -> ModifierHotkeyAction? {
        switch event {
        case let .modifierChanged(isDown: true, hasOtherModifiers):
            guard !isPressed, !hasOtherModifiers else { return nil }
            isPressed = true
            chordInterruptedTap = false
            if mode == .holdToTalk {
                holdRecordingActive = true
                return .startRecording
            }
            return nil

        case let .modifierChanged(isDown: false, hasOtherModifiers):
            guard isPressed else { return nil }
            isPressed = false
            defer { chordInterruptedTap = false }
            if mode == .holdToTalk {
                guard holdRecordingActive else { return nil }
                holdRecordingActive = false
                return .stopRecording
            }
            guard !chordInterruptedTap, !hasOtherModifiers else { return nil }
            return .toggleRecording

        case .otherKeyDown:
            guard isPressed else { return nil }
            chordInterruptedTap = true
            guard mode == .holdToTalk, holdRecordingActive else { return nil }
            holdRecordingActive = false
            return .stopRecording
        }
    }
}
