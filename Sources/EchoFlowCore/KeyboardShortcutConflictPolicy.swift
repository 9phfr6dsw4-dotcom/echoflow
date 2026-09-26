import Foundation

public enum KeyboardShortcutConflictPolicy {
    public static func conflicts(
        _ candidate: KeyboardShortcutDescriptor,
        with otherShortcuts: [KeyboardShortcutDescriptor?],
        reservedModifierFlags: KeyboardShortcutModifierFlags = []
    ) -> Bool {
        if !candidate.requiredModifierFlags.intersection(reservedModifierFlags).isEmpty {
            return true
        }
        return otherShortcuts.compactMap { $0 }.contains { other in
            candidate.keyCode == other.keyCode
                && candidate.requiredModifierFlags == other.requiredModifierFlags
        }
    }
}
