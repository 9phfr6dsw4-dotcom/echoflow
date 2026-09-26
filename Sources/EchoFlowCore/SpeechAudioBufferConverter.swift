import AVFoundation
import Foundation

public final class SpeechAudioBufferConverter {
    public enum ConversionError: LocalizedError, Equatable {
        case unsupportedFormats
        case emptyInput
        case conversionFailed(String)
        case noOutput

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormats:
                return "The microphone audio formats cannot be converted for speech recognition."
            case .emptyInput:
                return "The microphone supplied an empty audio buffer."
            case .conversionFailed(let message):
                return "Audio conversion failed: \(message)"
            case .noOutput:
                return "Audio conversion produced no samples."
            }
        }
    }

    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()

    public init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ConversionError.unsupportedFormats
        }
        converter.primeMethod = .none
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Converts synchronously; callers must not mutate `input` until this method returns.
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        guard input.frameLength > 0 else {
            throw ConversionError.emptyInput
        }

        let sampleRatio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * sampleRatio) + 64
        guard estimatedFrames.isFinite, estimatedFrames > 0, estimatedFrames < Double(UInt32.max) else {
            throw ConversionError.conversionFailed("The input buffer is too large.")
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            throw ConversionError.conversionFailed("Could not allocate an output buffer.")
        }

        let inputSource = AudioConverterInputSource(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputSource.nextBuffer(status: inputStatus)
        }

        if status == .error {
            throw ConversionError.conversionFailed(conversionError?.localizedDescription ?? "Unknown converter error.")
        }
        guard output.frameLength > 0 else {
            throw ConversionError.noOutput
        }
        return output
    }
}

/// Owns an immutable buffer for the duration of AVAudioConverter's synchronous callback.
/// The lock serializes the one-shot handoff across the converter's @Sendable input block.
private final class AudioConverterInputSource: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}
