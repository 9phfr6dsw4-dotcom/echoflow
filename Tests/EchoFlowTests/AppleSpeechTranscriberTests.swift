import Foundation
import Speech
import XCTest
@testable import EchoFlowCore

final class AppleSpeechTranscriberTests: XCTestCase {
    func testTranscribesGeneratedAudioLocally() async throws {
        guard let samplePath = ProcessInfo.processInfo.environment["ECHOFLOW_TEST_AUDIO"] else {
            throw XCTSkip("The macOS CI workflow provides a generated speech sample.")
        }
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("This runner's hardware does not support SpeechTranscriber.")
        }

        let service = AppleSpeechTranscriber()
        let localeIdentifier = try await service.prepare(localeIdentifier: "en-US")
        let transcript = try await service.transcribe(
            audioFileAt: URL(fileURLWithPath: samplePath),
            localeIdentifier: localeIdentifier
        )
        let normalized = String(transcript.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace })

        XCTAssertTrue(normalized.contains("echo flow"), "Unexpected transcription: \(transcript)")
        XCTAssertTrue(normalized.contains("this mac"), "Unexpected transcription: \(transcript)")
    }
}
