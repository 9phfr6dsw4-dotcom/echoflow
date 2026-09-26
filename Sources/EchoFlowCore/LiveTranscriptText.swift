import Foundation

public struct LiveTranscriptText: Equatable, Sendable {
    public private(set) var finalizedText = ""
    public private(set) var volatileText = ""

    public init() {}

    public var visibleText: String {
        Self.join(finalizedText, volatileText)
    }

    public mutating func consume(text: String, isFinal: Bool) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !normalized.isEmpty {
                finalizedText = Self.join(finalizedText, normalized)
            }
            volatileText = ""
        } else {
            volatileText = normalized
        }
    }

    public mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return "\(lhs) \(rhs)"
    }
}
