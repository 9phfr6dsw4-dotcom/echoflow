import AVFoundation
import Foundation
import XCTest
@testable import EchoFlowCore

final class AudioTapHandlerFactoryTests: XCTestCase {
    func testAppleSpeechStyleTapHandlerCreatedOnMainActorRunsOnBackgroundQueue() async throws {
        let probe = TapCallbackProbe()
        let handler = await MainActor.run {
            AudioTapHandlerFactory.make { _ in probe.recordCallbackThread() }
        }

        try invokeOnBackgroundQueue(handler, probe: probe)
    }

    func testLocalModelStyleTapHandlerCreatedOnMainActorRunsOnBackgroundQueue() async throws {
        let probe = TapCallbackProbe()
        let handler = await MainActor.run {
            AudioTapHandlerFactory.make { _ in probe.recordCallbackThread() }
        }

        try invokeOnBackgroundQueue(handler, probe: probe)
    }

    private func invokeOnBackgroundQueue(
        _ handler: @escaping AudioTapHandlerFactory.Handler,
        probe: TapCallbackProbe
    ) throws {
        DispatchQueue.global(qos: .userInitiated).async {
            probe.invoke(handler)
        }

        XCTAssertEqual(probe.completed.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(probe.wasCalledOnMainThread, false)
    }
}

private final class TapCallbackProbe: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callbackWasOnMainThread: Bool?

    var wasCalledOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return callbackWasOnMainThread
    }

    func invoke(_ handler: AudioTapHandlerFactory.Handler) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480) else {
            recordCallbackThread(setupFailed: true)
            return
        }
        buffer.frameLength = 480
        handler(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }

    func recordCallbackThread(setupFailed: Bool = false) {
        lock.lock()
        callbackWasOnMainThread = setupFailed ? nil : Thread.isMainThread
        lock.unlock()
        completed.signal()
    }
}
