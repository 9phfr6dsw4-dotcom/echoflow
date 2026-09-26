import AVFoundation
import XCTest
@testable import EchoFlowCore

final class ParakeetPreviewAudioQueueTests: XCTestCase {
    func testTapCopiesAudioBeforeTheSourceBufferIsReusedAndConvertsOffTap() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000, channels: 2, interleaved: false))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        source.frameLength = 4_800
        for channel in 0..<2 {
            source.floatChannelData![channel].update(repeating: 0.25, count: 4_800)
        }
        let queue = ParakeetPreviewAudioQueue()
        let tap = AudioTapHandlerFactory.make { buffer in queue.append(buffer) }
        tap(source, AVAudioTime(sampleTime: 0, atRate: 48_000))
        source.floatChannelData![0].update(repeating: 0, count: 4_800)
        source.floatChannelData![1].update(repeating: 0, count: 4_800)
        queue.finish()
        var iterator = queue.buffers.makeAsyncIterator()
        let nextBuffer = await iterator.next()
        let captured = try XCTUnwrap(nextBuffer).buffer
        XCTAssertEqual(captured.floatChannelData![0][0], 0.25)
        let converter = try SpeechAudioBufferConverter(inputFormat: inputFormat, outputFormat: outputFormat)
        let converted = try converter.convert(captured)
        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(converted.frameLength, 0)
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testPreviewContinuesPastFormerLifetimeCap() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let queue = ParakeetPreviewAudioQueue()
        var iterator = queue.buffers.makeAsyncIterator()
        for second in 1...50 {
            queue.append(buffer)
            let next = await iterator.next()
            XCTAssertNotNil(next, "Audio was lost at second \(second)")
            XCTAssertTrue(queue.isActive, "Preview stopped at second \(second)")
        }
        queue.finish()
        let end = await iterator.next()
        XCTAssertNil(end)
        XCTAssertFalse(queue.isActive)
    }

    func testPacingAllowsOnlyOneWindowOfUnprocessedAudio() {
        var pacing = ParakeetPreviewPacing(sampleRate: 16_000, chunkSeconds: 1)
        XCTAssertFalse(pacing.recordSent(frames: 4_000))
        XCTAssertTrue(pacing.recordSent(frames: 12_000))
        XCTAssertTrue(pacing.needsUpdate)
        pacing.didReceiveUpdate()
        XCTAssertFalse(pacing.needsUpdate)
        XCTAssertFalse(pacing.recordSent(frames: 8_000))
        XCTAssertTrue(pacing.recordSent(frames: 8_000))
    }

    func testPacingCannotConsumeMoreAudioUntilAcknowledged() {
        var pacing = ParakeetPreviewPacing(sampleRate: 16_000, chunkSeconds: 1)
        XCTAssertTrue(pacing.recordSent(frames: 16_000))
        XCTAssertTrue(pacing.needsUpdate)
        pacing.didReceiveUpdate()
        XCTAssertFalse(pacing.recordSent(frames: 15_999))
        XCTAssertTrue(pacing.recordSent(frames: 1))
    }

    func testQueueStopsOnBacklogOverflowRatherThanDroppingAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let queue = ParakeetPreviewAudioQueue()
        for _ in 0..<513 { queue.append(buffer) }
        XCTAssertFalse(queue.isActive)
    }

    func testSegmentsRetainEarlierWordsAcrossMultipleResets() {
        var segments = ParakeetPreviewSegments()
        XCTAssertEqual(segments.displaying("first"), "first")
        segments.completed("first two")
        XCTAssertEqual(segments.displaying("third"), "first two third")
        segments.completed("third four")
        XCTAssertEqual(segments.displaying(""), "first two third four")
    }
}
