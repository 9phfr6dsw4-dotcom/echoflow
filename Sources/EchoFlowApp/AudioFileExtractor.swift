import AVFoundation
import Foundation

/// Decodes the audio of an imported audio or video file into a temporary 16 kHz mono CAF file,
/// which every EchoFlow engine can read. The caller deletes the file when done.
enum AudioFileExtractor {
    struct ExtractedAudio: Sendable {
        let url: URL
        let duration: TimeInterval
    }

    enum ExtractionError: LocalizedError {
        case noAudioTrack
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "This file has no audio track to transcribe."
            case .decodingFailed(let detail):
                return "EchoFlow couldn't read the audio in this file (\(detail))."
            }
        }
    }

    static func extractAudio(from sourceURL: URL) async throws -> ExtractedAudio {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExtractionError.noAudioTrack
        }
        let durationSeconds = try await asset.load(.duration).seconds
        let sampleRate = 16_000.0
        var monoLayout = AudioChannelLayout()
        monoLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = withUnsafeBytes(of: monoLayout) { Data($0) }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ExtractionError.decodingFailed("unsupported output format")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExtractionError.decodingFailed("unsupported audio track")
        }
        reader.add(output)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoFlowFile-\(UUID().uuidString)")
            .appendingPathExtension("caf")
        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard reader.startReading() else {
                throw ExtractionError.decodingFailed(reader.error?.localizedDescription ?? "could not start reading")
            }
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
                guard frameCount > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
                buffer.frameLength = frameCount
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sampleBuffer,
                    at: 0,
                    frameCount: Int32(frameCount),
                    into: buffer.mutableAudioBufferList
                )
                guard status == noErr else {
                    throw ExtractionError.decodingFailed("audio decode error \(status)")
                }
                try file.write(from: buffer)
            }
            guard reader.status == .completed else {
                throw ExtractionError.decodingFailed(reader.error?.localizedDescription ?? "reading stopped early")
            }
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return ExtractedAudio(url: outputURL, duration: durationSeconds.isFinite ? durationSeconds : 0)
    }
}
