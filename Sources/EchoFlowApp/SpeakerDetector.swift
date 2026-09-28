import EchoFlowCore
import FluidAudio
import Foundation

/// Finds who is speaking when in an audio file, on this Mac, with FluidAudio's offline speaker
/// diarization (pyannote community-1 Core ML models). The models download once, the first time
/// speaker detection is used, into FluidAudio's model folder.
enum SpeakerDetector {
    /// - Parameters:
    ///   - speakerCount: The number of speakers, or nil to detect it automatically.
    ///   - onProgress: Fraction of the audio analyzed so far. The first call (0) comes once the
    ///     models are ready, so the screen can switch from "getting ready" to a percentage.
    static func speakerTurns(
        audioURL: URL,
        speakerCount: Int?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerTurn] {
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = speakerCount
        // Denser analysis windows and shorter minimum segments catch quick back-and-forth and
        // short interjections (FluidAudio's documented setting for rapid exchanges), at the cost
        // of some extra time.
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0.5
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        try Task.checkCancellation()
        onProgress(0)
        let result = try await manager.process(audioURL, progressCallback: { processed, total in
            guard total > 0 else { return }
            onProgress(min(max(Double(processed) / Double(total), 0), 1))
        })
        return result.segments.map { segment in
            SpeakerTurn(
                speakerID: segment.speakerId,
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds)
            )
        }
    }
}
