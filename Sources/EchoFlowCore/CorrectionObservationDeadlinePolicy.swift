import Foundation

/// Centralizes the strict end boundary for transient correction observation.
public enum CorrectionObservationDeadlinePolicy {
    public static func isOpen(
        deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> Bool {
        now < deadline
    }
}
