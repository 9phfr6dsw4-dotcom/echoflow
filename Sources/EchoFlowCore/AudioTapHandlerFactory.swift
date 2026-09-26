import AVFoundation

/// A realtime-safe adapter for callbacks installed on AVAudioEngine taps.
/// The sendable receive closure is nonisolated, so it cannot inherit MainActor isolation
/// from the call site that configures the audio engine.
public enum AudioTapHandlerFactory {
    public typealias Handler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    public static func make(
        receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> Handler {
        { buffer, _ in
            receive(buffer)
        }
    }
}
