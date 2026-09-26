import Foundation

/// Modifier keys that may be required by a global keyboard shortcut.
public struct KeyboardShortcutModifierFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
    public static let function = Self(rawValue: 1 << 4)

    private static let supportedMask = command.union(shift).union(option).union(control).union(function).rawValue

    fileprivate var isValidShortcutChord: Bool {
        !isEmpty && rawValue & ~Self.supportedMask == 0
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A non-modifier key and the exact modifier chord required to activate it.
public struct KeyboardShortcutDescriptor: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let requiredModifierFlags: KeyboardShortcutModifierFlags
    public let displayLabel: String?

    /// Returns nil for shortcuts without a supported modifier chord.
    public init?(
        keyCode: UInt16,
        requiredModifierFlags: KeyboardShortcutModifierFlags,
        displayLabel: String? = nil
    ) {
        guard requiredModifierFlags.isValidShortcutChord else { return nil }
        self.keyCode = keyCode
        self.requiredModifierFlags = requiredModifierFlags
        self.displayLabel = displayLabel
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case requiredModifierFlags
        case displayLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let requiredModifierFlags = try container.decode(KeyboardShortcutModifierFlags.self, forKey: .requiredModifierFlags)
        let displayLabel = try container.decodeIfPresent(String.self, forKey: .displayLabel)

        guard let descriptor = Self(
            keyCode: keyCode,
            requiredModifierFlags: requiredModifierFlags,
            displayLabel: displayLabel
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .requiredModifierFlags,
                in: container,
                debugDescription: "A shortcut must require at least one supported modifier."
            )
        }
        self = descriptor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(requiredModifierFlags, forKey: .requiredModifierFlags)
        try container.encodeIfPresent(displayLabel, forKey: .displayLabel)
    }
}

public enum KeyboardShortcutEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16, modifierFlags: KeyboardShortcutModifierFlags, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
}

/// Recognizes primary and optionally enabled backup shortcuts without duplicate firing.
public struct KeyboardShortcutRecognizer: Sendable {
    private let primary: KeyboardShortcutDescriptor
    private let backup: KeyboardShortcutDescriptor?
    private let isBackupEnabled: Bool
    private let mode: ModifierHotkeyMode

    private var pressedShortcutKeys: Set<UInt16> = []
    private var activeGestureKeyCode: UInt16?
    private var gestureIsActive = false

    public init(
        primary: KeyboardShortcutDescriptor,
        backup: KeyboardShortcutDescriptor? = nil,
        isBackupEnabled: Bool = false,
        mode: ModifierHotkeyMode = .tapToToggle
    ) {
        self.primary = primary
        self.backup = backup
        self.isBackupEnabled = isBackupEnabled
        self.mode = mode
    }

    public mutating func consume(_ event: KeyboardShortcutEvent) -> ModifierHotkeyAction? {
        switch event {
        case let .keyDown(keyCode, modifierFlags, isRepeat):
            guard !isRepeat, matches(keyCode: keyCode, modifierFlags: modifierFlags) else { return nil }
            guard pressedShortcutKeys.insert(keyCode).inserted else { return nil }
            guard !gestureIsActive else { return nil }

            gestureIsActive = true
            activeGestureKeyCode = keyCode
            return mode == .tapToToggle ? .toggleRecording : .startRecording

        case let .keyUp(keyCode):
            guard pressedShortcutKeys.remove(keyCode) != nil else { return nil }

            var action: ModifierHotkeyAction?
            if activeGestureKeyCode == keyCode {
                activeGestureKeyCode = nil
                if mode == .holdToTalk {
                    action = .stopRecording
                }
            }

            if pressedShortcutKeys.isEmpty {
                gestureIsActive = false
            }
            return action
        }
    }

    private func matches(keyCode: UInt16, modifierFlags: KeyboardShortcutModifierFlags) -> Bool {
        if keyCode == primary.keyCode && modifierFlags == primary.requiredModifierFlags {
            return true
        }
        guard isBackupEnabled, let backup else { return false }
        return keyCode == backup.keyCode && modifierFlags == backup.requiredModifierFlags
    }
}
