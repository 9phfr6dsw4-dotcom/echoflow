/// The parts of a text field's Accessibility state that change when text is inserted.
public struct AccessibilityEditState: Equatable, Sendable {
    public let characterCount: Int?
    public let selectedRange: InsertedTextCorrectionRange?

    public init(characterCount: Int?, selectedRange: InsertedTextCorrectionRange?) {
        self.characterCount = characterCount
        self.selectedRange = selectedRange
    }
}

public enum AccessibilityInsertionCheck: Equatable, Sendable {
    /// The field's length or caret moved, so the text reached it.
    case changed
    /// The field reported the same length and caret, so the insertion was silently ignored.
    case unchanged
    /// The field exposes neither length nor caret, so the result cannot be compared.
    case unverifiable
}

/// Some apps (notably Chromium and Electron text fields) report success when Accessibility sets
/// the selected text but leave the field unchanged. Comparing the field before and after tells a
/// real insertion apart from a silently ignored one.
public enum AccessibilityInsertionVerification {
    public static func check(
        before: AccessibilityEditState,
        after: AccessibilityEditState
    ) -> AccessibilityInsertionCheck {
        var comparedAnything = false
        if let beforeCount = before.characterCount, let afterCount = after.characterCount {
            comparedAnything = true
            if beforeCount != afterCount { return .changed }
        }
        if let beforeRange = before.selectedRange, let afterRange = after.selectedRange {
            comparedAnything = true
            if beforeRange != afterRange { return .changed }
        }
        return comparedAnything ? .unchanged : .unverifiable
    }
}
