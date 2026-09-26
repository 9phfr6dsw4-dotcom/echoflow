import Foundation

public enum CustomVocabularyStoreError: Error, Equatable, Sendable {
    case invalidTerm
    case termTooLong(maximumLength: Int)
    case duplicateTerm
    case termNotFound
}

public struct CustomVocabularyTerm: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let term: String

    fileprivate init(id: UUID, term: String) {
        self.id = id
        self.term = term
    }
}

/// An in-memory, local-only collection of explicitly added vocabulary terms.
public struct CustomVocabularyStore: Codable, Equatable, Sendable {
    public static let maximumTermLength = 100

    public private(set) var terms: [CustomVocabularyTerm]

    public init() {
        terms = []
    }

    /// Adds a term, returning the existing entry when its normalized form is already present.
    @discardableResult
    public mutating func addTerm(_ rawTerm: String) throws -> CustomVocabularyTerm {
        let cleanedTerm = try Self.validatedTerm(rawTerm)
        let normalizedTerm = Self.normalized(cleanedTerm)

        if let existing = terms.first(where: { Self.normalized($0.term) == normalizedTerm }) {
            return existing
        }

        let entry = CustomVocabularyTerm(id: UUID(), term: cleanedTerm)
        terms.append(entry)
        sortTerms()
        return entry
    }

    /// Replaces a term while retaining its stable identity.
    @discardableResult
    public mutating func editTerm(id: UUID, to rawTerm: String) throws -> CustomVocabularyTerm {
        guard let index = terms.firstIndex(where: { $0.id == id }) else {
            throw CustomVocabularyStoreError.termNotFound
        }

        let cleanedTerm = try Self.validatedTerm(rawTerm)
        let normalizedTerm = Self.normalized(cleanedTerm)
        guard !terms.contains(where: {
            $0.id != id && Self.normalized($0.term) == normalizedTerm
        }) else {
            throw CustomVocabularyStoreError.duplicateTerm
        }

        let updatedEntry = CustomVocabularyTerm(id: id, term: cleanedTerm)
        terms[index] = updatedEntry
        sortTerms()
        return updatedEntry
    }

    /// Removes a term by identity. Returns false when the identity is not present.
    @discardableResult
    public mutating func removeTerm(id: UUID) -> Bool {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return false }
        terms.remove(at: index)
        return true
    }

    private mutating func sortTerms() {
        terms.sort { left, right in
            let leftNormalized = Self.normalized(left.term)
            let rightNormalized = Self.normalized(right.term)
            if leftNormalized != rightNormalized { return leftNormalized < rightNormalized }
            if left.term != right.term { return left.term < right.term }
            return left.id.uuidString < right.id.uuidString
        }
    }

    private static func validatedTerm(_ rawTerm: String) throws -> String {
        let cleanedTerm = rawTerm
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !cleanedTerm.isEmpty else {
            throw CustomVocabularyStoreError.invalidTerm
        }

        let containsDisallowedControl = rawTerm.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && !scalar.properties.isWhitespace
        }
        guard !containsDisallowedControl else {
            throw CustomVocabularyStoreError.invalidTerm
        }
        guard cleanedTerm.count <= maximumTermLength else {
            throw CustomVocabularyStoreError.termTooLong(maximumLength: maximumTermLength)
        }
        return cleanedTerm
    }

    private static func normalized(_ term: String) -> String {
        term.lowercased()
    }
}
