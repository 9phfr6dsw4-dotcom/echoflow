import AVFoundation
import Foundation

/// An independently allocated audio buffer, written once before being sent to the stream.
/// The source tap never sees this instance; the consumer is its sole reader and never mutates it.
public struct ParakeetCapturedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    fileprivate init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// Copies tap-owned PCM into a bounded, single-consumer stream. No transcription,
/// format conversion, main-actor work, or UI callbacks occur on the audio thread.
public final class ParakeetPreviewAudioQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<ParakeetCapturedAudioBuffer>.Continuation
    public let buffers: AsyncStream<ParakeetCapturedAudioBuffer>
    private var active = true

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// A bounded tap backlog; the consumer separately bounds FluidAudio input.
    public init() {
        let (stream, builder) = AsyncStream<ParakeetCapturedAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(512)
        )
        buffers = stream
        continuation = builder
    }

    public func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard active, input.frameLength > 0 else { return }
        guard let copy = Self.copy(input) else {
            stopLocked()
            return
        }

        switch continuation.yield(ParakeetCapturedAudioBuffer(copy)) {
        case .enqueued: break
        case .dropped, .terminated: stopLocked() // Never transcribe audio with a gap.
        @unknown default: stopLocked()
        }
    }

    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard active else { return }
        active = false
        continuation.finish()
    }

    private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            return nil
        }
        output.frameLength = input.frameLength
        let sources = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destinations = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard sources.count == destinations.count else { return nil }
        for index in sources.indices {
            guard let source = sources[index].mData, let destination = destinations[index].mData,
                  destinations[index].mDataByteSize >= sources[index].mDataByteSize else { return nil }
            destination.copyMemory(from: source, byteCount: Int(sources[index].mDataByteSize))
        }
        return output
    }
}

/// Permit only one decoded window of audio in FluidAudio's unbounded input stream.
public struct ParakeetPreviewPacing {
    private let windowFrames: Int
    private var sentFrames = 0
    public private(set) var needsUpdate = false

    public init(sampleRate: Double, chunkSeconds: Double) {
        windowFrames = max(1, Int(sampleRate * chunkSeconds))
    }

    /// Call only after the previous window was acknowledged.
    public mutating func recordSent(frames: Int) -> Bool {
        precondition(!needsUpdate)
        sentFrames += frames
        needsUpdate = sentFrames >= windowFrames
        return needsUpdate
    }

    public mutating func didReceiveUpdate() {
        sentFrames = 0
        needsUpdate = false
    }
}

/// Preview-only text across independent, finite inference sessions.
public struct ParakeetPreviewSegments {
    private var prefix = ""

    public init() {}

    public func displaying(_ current: String) -> String {
        [prefix, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public mutating func completed(_ final: String) {
        prefix = displaying(final)
    }
}
