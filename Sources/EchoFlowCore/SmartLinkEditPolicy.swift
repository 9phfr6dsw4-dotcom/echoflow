import Foundation

public struct SmartLinkEditValues: Equatable, Sendable {
    public let phrase: String
    public let destinationURL: String

    public init(phrase: String, destinationURL: String) {
        self.phrase = phrase
        self.destinationURL = destinationURL
    }
}

public enum SmartLinkEditPolicy {
    /// Editing either field keeps the existing value for the field left untouched.
    public static func values(
        existingPhrase: String,
        existingDestinationURL: String,
        phraseDraft: String?,
        destinationURLDraft: String?
    ) -> SmartLinkEditValues {
        SmartLinkEditValues(
            phrase: phraseDraft ?? existingPhrase,
            destinationURL: destinationURLDraft ?? existingDestinationURL
        )
    }
}
