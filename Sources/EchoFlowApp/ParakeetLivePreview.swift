@preconcurrency import AVFoundation
import EchoFlowCore
import FluidAudio
import Foundation

/// Optional, best-effort display path. Never supplies the delivered transcript.
enum ParakeetLivePreview {
    private static let chunkSeconds = 1.0
    private static let segmentSeconds = 24.0

    static func run(
        audio: ParakeetPreviewAudioQueue,
        modelDirectory: URL,
        languageIdentifier: String,
        onUpdate: @escaping @Sendable (String) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let code = languageIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init)?.lowercased()
        // v0.17.2 does not use hypothesisChunkSeconds in its recognition loop.
        // With no right lookahead, the first window is eligible after one second.
        let config = SlidingWindowAsrConfig(
            chunkSeconds: chunkSeconds,
            hypothesisChunkSeconds: 1,
            leftContextSeconds: 2,
            rightContextSeconds: 0,
            minContextForConfirmation: 8,
            confirmationThreshold: 0.85,
            language: code.flatMap(Language.init(rawValue:))
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        ) else { audio.finish(); return }

        do {
            // Load installed assets once. No download API and no CAF read in preview.
            let models = try AsrModels.loadLocal(
                from: modelDirectory, version: .v3, encoderPrecision: .int8V2
            )
            var converter: SpeechAudioBufferConverter?
            var iterator = audio.buffers.makeAsyncIterator()
            var segments = ParakeetPreviewSegments()

            while !Task.isCancelled {
                let manager = SlidingWindowAsrManager(config: config)
                var updates: Task<Void, Never>?
                do {
                    try await manager.loadModels(models)
                    try Task.checkCancellation()
                    try await manager.startStreaming()
                    // Register before feeding any audio, so even the first update is observed.
                    let stream = await manager.transcriptionUpdates
                    let (ackStream, acknowledge) = AsyncStream<Void>.makeStream(
                        bufferingPolicy: .bufferingOldest(1)
                    )
                    var ackIterator = ackStream.makeAsyncIterator()
                    let prefix = segments.displaying("")
                    updates = Task {
                        for await _ in stream {
                            guard !Task.isCancelled else { break }
                            let confirmed = await manager.confirmedTranscript
                            let volatile = await manager.volatileTranscript
                            let current = [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
                            let text = [prefix, current].filter { !$0.isEmpty }.joined(separator: " ")
                            if !text.isEmpty { onUpdate(text) }
                            acknowledge.yield(())
                        }
                        acknowledge.finish()
                    }

                    var pacing = ParakeetPreviewPacing(sampleRate: 16_000, chunkSeconds: chunkSeconds)
                    var segmentFrames = 0
                    var reachedEnd = false
                    while segmentFrames < Int(segmentSeconds * 16_000) {
                        guard let captured = await iterator.next() else {
                            reachedEnd = true
                            break
                        }
                        try Task.checkCancellation()
                        let buffer = captured.buffer
                        // The tap only copies; conversion and inference are on this worker.
                        let activeConverter: SpeechAudioBufferConverter
                        if let converter {
                            activeConverter = converter
                        } else {
                            let created = try SpeechAudioBufferConverter(
                                inputFormat: buffer.format, outputFormat: format
                            )
                            converter = created
                            activeConverter = created
                        }
                        let converted = try activeConverter.convert(buffer)
                        await manager.streamAudio(converted)
                        let frames = Int(converted.frameLength)
                        segmentFrames += frames
                        if pacing.recordSent(frames: frames) {
                            // A window failure emits no update in FluidAudio. Stop the
                            // optional path rather than wait forever or grow its input.
                            let watchdog = Task {
                                do {
                                    try await Task.sleep(for: .seconds(10))
                                    acknowledge.finish()
                                } catch { /* The window was acknowledged. */ }
                            }
                            let acknowledged: Void? = await ackIterator.next()
                            watchdog.cancel()
                            try Task.checkCancellation()
                            guard acknowledged != nil else { throw CancellationError() }
                            pacing.didReceiveUpdate()
                        }
                    }
                    try Task.checkCancellation()
                    // finish() waits for the recognizer and flushes the short tail.
                    // A fresh manager bounds its unbounded token/audio state per segment.
                    let final = try await manager.finish()
                    updates?.cancel()
                    await updates?.value
                    acknowledge.finish()
                    segments.completed(final)
                    if !final.isEmpty { onUpdate(segments.displaying("")) }
                    await manager.cleanup()
                    if reachedEnd { return }
                } catch {
                    audio.finish()
                    // cancel() alone does not join FluidAudio's recognizer task.
                    await manager.cancel()
                    _ = try? await manager.finish()
                    updates?.cancel()
                    await updates?.value
                    await manager.cleanup()
                    return
                }
            }
        } catch {
            // Preview failure never changes the CAF or the final batch transcription.
            audio.finish()
        }
    }
}
