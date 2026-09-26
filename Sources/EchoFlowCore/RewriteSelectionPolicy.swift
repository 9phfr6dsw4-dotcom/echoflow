import Foundation

public struct RewriteSelectionSnapshot: Equatable, Sendable {
    public let target: TextInsertionSnapshot
    public let selectedText: String
    public let rangeLocation: Int
    public let rangeLength: Int
    public let fieldCharacterCount: Int?

    public init(
        target: TextInsertionSnapshot,
        selectedText: String,
        rangeLocation: Int,
        rangeLength: Int,
        fieldCharacterCount: Int? = nil
    ) {
        self.target = target
        self.selectedText = selectedText
        self.rangeLocation = rangeLocation
        self.rangeLength = rangeLength
        self.fieldCharacterCount = fieldCharacterCount
    }
}

public enum RewriteSelectionDecision: Error, Equatable, Sendable {
    case allowed
    case noSelection
    case unsupportedField
    case secureField
    case excludedApplication
    case policyUnavailable
    case invalidRange
    case selectionTooLarge
}

public enum RewriteSelectionPolicy {
    public static let maximumSelectionCharacters = 6_000
    private static let supportedRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField"]

    public static func captureDecision(
        for selection: RewriteSelectionSnapshot,
        additionalExcludedBundleIdentifiers: Set<String>? = Set<String>()
    ) -> RewriteSelectionDecision {
        if let targetDecision = targetDecision(
            for: selection.target,
            additionalExcludedBundleIdentifiers: additionalExcludedBundleIdentifiers
        ) {
            return targetDecision
        }
        guard !selection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .noSelection
        }
        guard selection.rangeLocation >= 0,
              selection.rangeLength > 0,
              selection.selectedText.utf16.count == selection.rangeLength,
              let fieldCharacterCount = selection.fieldCharacterCount,
              fieldCharacterCount >= 0,
              selection.rangeLocation <= fieldCharacterCount,
              selection.rangeLength <= fieldCharacterCount - selection.rangeLocation else {
            return .invalidRange
        }
        guard selection.selectedText.count <= maximumSelectionCharacters else {
            return .selectionTooLarge
        }
        return .allowed
    }

    /// Validates the focused target without reading any selected or field text.
    public static func targetDecision(
        for target: TextInsertionSnapshot,
        additionalExcludedBundleIdentifiers: Set<String>? = Set<String>()
    ) -> RewriteSelectionDecision? {
        if target.focusedRole == "AXSecureTextField" || target.focusedSubrole == "AXSecureTextField" {
            return .secureField
        }
        guard let additionalExcludedBundleIdentifiers else { return .policyUnavailable }
        let policy = TextInsertionPolicy(
            excludedBundleIdentifiers: TextInsertionPolicy.defaultExcludedBundleIdentifiers
                .union(additionalExcludedBundleIdentifiers)
        )
        guard !policy.isExcluded(bundleIdentifier: target.bundleIdentifier) else {
            return .excludedApplication
        }
        guard target.processIdentifier > 0,
              let bundleIdentifier = target.bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let role = target.focusedRole,
              supportedRoles.contains(role) else {
            return .unsupportedField
        }
        return nil
    }

    public static func canReplace(
        captured: RewriteSelectionSnapshot,
        current: RewriteSelectionSnapshot,
        sameFocusedElement: Bool,
        additionalExcludedBundleIdentifiers: Set<String>? = Set<String>()
    ) -> Bool {
        guard sameFocusedElement,
              captureDecision(for: captured, additionalExcludedBundleIdentifiers: additionalExcludedBundleIdentifiers) == .allowed,
              captureDecision(for: current, additionalExcludedBundleIdentifiers: additionalExcludedBundleIdentifiers) == .allowed else {
            return false
        }
        let capturedBundle = captured.target.bundleIdentifier?.lowercased()
        let currentBundle = current.target.bundleIdentifier?.lowercased()
        return captured.target.processIdentifier == current.target.processIdentifier
            && capturedBundle == currentBundle
            && captured.target.focusedRole == current.target.focusedRole
            && captured.target.focusedSubrole == current.target.focusedSubrole
            && captured.selectedText == current.selectedText
            && captured.rangeLocation == current.rangeLocation
            && captured.rangeLength == current.rangeLength
    }
}
