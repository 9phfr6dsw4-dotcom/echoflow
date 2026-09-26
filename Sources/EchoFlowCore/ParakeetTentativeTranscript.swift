import Foundation

/// Recording-scoped display state. The batch transcript is deliberately not held here.
public struct ParakeetTentativeTranscript: Sendable {
    public private(set) var text = ""
    private var activeToken: UUID?

    public init() {}

    @discardableResult
    public mutating func begin() -> UUID {
        let token = UUID()
        activeToken = token
        text = ""
        return token
    }

    @discardableResult
    public mutating func accept(_ text: String, for token: UUID) -> Bool {
        guard activeToken == token else { return false }
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return true
    }

    public mutating func stop(_ token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        text = ""
    }
}
