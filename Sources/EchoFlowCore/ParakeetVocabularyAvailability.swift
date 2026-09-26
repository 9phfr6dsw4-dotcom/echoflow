import Foundation

/// Determines whether Parakeet CTC vocabulary rescoring can run.
/// Missing rescoring inputs must never block the base Parakeet transcript.
public enum ParakeetVocabularyAvailability {
    public static func canApplyCustomTerms(
        hasTerms: Bool,
        companionInstalled: Bool,
        hasTokenTimings: Bool
    ) -> Bool {
        hasTerms && companionInstalled && hasTokenTimings
    }
}
