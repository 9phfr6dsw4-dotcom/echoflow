public struct RecordingDiscardGate: Sendable {
    private enum State: Sendable {
        case idle
        case pending
        case cleaning
    }

    private var state = State.idle

    public init() {}

    public var blocksRecordingEvents: Bool {
        if case .idle = state { return false }
        return true
    }

    @discardableResult
    public mutating func request() -> Bool {
        guard case .idle = state else { return false }
        state = .pending
        return true
    }

    @discardableResult
    public mutating func beginCleanup() -> Bool {
        guard case .pending = state else { return false }
        state = .cleaning
        return true
    }

    public mutating func finishCleanup() {
        guard case .cleaning = state else { return }
        state = .idle
    }
}
