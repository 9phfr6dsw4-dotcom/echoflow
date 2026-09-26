import Foundation

/// Resolves an empty UI selection to the current system locale while preserving
/// an explicitly pinned language identifier.
public enum TranscriptionLanguagePreference {
    public static func resolve(
        _ preferredIdentifier: String?,
        systemLanguageIdentifier: String
    ) -> String {
        guard let preferredIdentifier else { return systemLanguageIdentifier }
        let trimmed = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? systemLanguageIdentifier : trimmed
    }
}
