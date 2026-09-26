import Foundation

public struct SmartLink: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let phrase: String
    public let destinationURL: String

    public init(id: UUID = UUID(), phrase: String, destinationURL: String) {
        self.id = id
        self.phrase = phrase
        self.destinationURL = destinationURL
    }
}

public enum SmartLinkStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidPhrase
    case invalidDestinationURL
    case duplicatePhrase
    case linkNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidPhrase:
            "Enter a phrase between 2 and 80 characters."
        case .invalidDestinationURL:
            "Enter an absolute HTTP or HTTPS link without a username or password."
        case .duplicatePhrase:
            "That smart-link phrase already exists."
        case .linkNotFound:
            "That smart link no longer exists."
        }
    }
}

/// Locally stored phrase-to-URL substitutions applied only to final transcripts.
public struct SmartLinkStore: Codable, Equatable, Sendable {
    public private(set) var links: [SmartLink]

    public init(links: [SmartLink] = []) {
        self.links = links
    }

    @discardableResult
    public mutating func add(phrase rawPhrase: String, destinationURL rawURL: String) throws -> SmartLink {
        let phrase = Self.normalizedPhrase(rawPhrase)
        let destinationURL = try Self.validatedURL(rawURL)
        try Self.validatePhrase(phrase)
        guard !links.contains(where: { Self.phraseKey($0.phrase) == Self.phraseKey(phrase) }) else {
            throw SmartLinkStoreError.duplicatePhrase
        }
        let link = SmartLink(phrase: phrase, destinationURL: destinationURL)
        links.append(link)
        return link
    }

    @discardableResult
    public mutating func edit(
        id: UUID,
        phrase rawPhrase: String,
        destinationURL rawURL: String
    ) throws -> SmartLink {
        guard let index = links.firstIndex(where: { $0.id == id }) else {
            throw SmartLinkStoreError.linkNotFound
        }
        let phrase = Self.normalizedPhrase(rawPhrase)
        let destinationURL = try Self.validatedURL(rawURL)
        try Self.validatePhrase(phrase)
        guard !links.enumerated().contains(where: {
            $0.offset != index && Self.phraseKey($0.element.phrase) == Self.phraseKey(phrase)
        }) else {
            throw SmartLinkStoreError.duplicatePhrase
        }
        let updated = SmartLink(id: id, phrase: phrase, destinationURL: destinationURL)
        links[index] = updated
        return updated
    }

    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return false }
        links.remove(at: index)
        return true
    }

    /// Replaces whole-phrase matches in one pass, preserving surrounding punctuation.
    /// Longer aliases are preferred when phrases overlap.
    public func applying(to text: String) -> String {
        guard !links.isEmpty, !text.isEmpty else { return text }
        let orderedLinks = links.sorted {
            if $0.phrase.count != $1.phrase.count { return $0.phrase.count > $1.phrase.count }
            return Self.phraseKey($0.phrase) < Self.phraseKey($1.phrase)
        }
        let alternatives = orderedLinks.map { link in
            link.phrase
                .split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
        }
        let pattern = "(?<![\\p{L}\\p{N}_])(" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }

        let destinations = Dictionary(
            orderedLinks.map { (Self.phraseKey($0.phrase), $0.destinationURL) },
            uniquingKeysWith: { first, _ in first }
        )
        var output = String()
        var cursor = text.startIndex
        for match in matches {
            guard let phraseRange = Range(match.range(at: 1), in: text),
                  let wholeRange = Range(match.range, in: text) else { continue }
            output.append(contentsOf: text[cursor..<wholeRange.lowerBound])
            let key = Self.phraseKey(String(text[phraseRange]))
            output.append(contentsOf: destinations[key] ?? String(text[phraseRange]))
            cursor = wholeRange.upperBound
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    private static func validatePhrase(_ phrase: String) throws {
        guard (2...80).contains(phrase.count), !phrase.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SmartLinkStoreError.invalidPhrase
        }
    }

    private static func normalizedPhrase(_ rawPhrase: String) -> String {
        rawPhrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func phraseKey(_ phrase: String) -> String {
        normalizedPhrase(phrase).lowercased()
    }

    private static func validatedURL(_ rawURL: String) throws -> String {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.url != nil else {
            throw SmartLinkStoreError.invalidDestinationURL
        }
        return value
    }
}
