import AVFoundation
import XCTest
@testable import EchoFlowCore

final class SpeechAudioBufferConverterTests: XCTestCase {
    func testConvertsMicrophoneBufferToAnalyzerFormat() throws {
        let inputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let outputFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        input.frameLength = 480
        input.floatChannelData?[0].initialize(repeating: 0, count: Int(input.frameLength))

        let converter = try SpeechAudioBufferConverter(inputFormat: inputFormat, outputFormat: outputFormat)
        let converted = try converter.convert(input)

        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertLessThanOrEqual(converted.frameLength, 176)
        XCTAssertGreaterThanOrEqual(converted.frameLength, 144)
    }
}
