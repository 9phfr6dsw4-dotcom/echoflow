import Foundation
import WhisperKit
import XCTest
@testable import EchoFlowCore

/// Opt-in REAL Core ML benchmark; the test never downloads, writes, or removes model assets.
/// CI provisions a pinned compiled tiny model and generated audio in RUNNER_TEMP.
/// Locally, supply any compatible compiled WhisperKit model and a short speech file:
/// ECHOFLOW_WHISPER_MODEL_DIRECTORY=/path/to/model-folder \
/// ECHOFLOW_WHISPER_BENCH_AUDIO=/path/to/speech.wav \
/// swift test --filter WhisperPerformanceTests
final class WhisperPerformanceTests: XCTestCase {
    private final class Session: @unchecked Sendable {
        let whisper: WhisperKit
        let tokenizer: TokenizerWrapper
        init(whisper: WhisperKit, tokenizer: TokenizerWrapper) {
            self.whisper = whisper
            self.tokenizer = tokenizer
        }
    }

    func testRealRepeatedDictationsBeforeAndAfterCache() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["ECHOFLOW_WHISPER_MODEL_DIRECTORY"],
              let audioPath = environment["ECHOFLOW_WHISPER_BENCH_AUDIO"] else {
            throw XCTSkip("Opt in with ECHOFLOW_WHISPER_MODEL_DIRECTORY and ECHOFLOW_WHISPER_BENCH_AUDIO")
        }
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
              FileManager.default.fileExists(atPath: audioPath) else {
            XCTFail("Specified tokenizer.json or speech recording is missing; no assets are downloaded")
            return
        }

        let load: @Sendable (URL) async throws -> Session = { folder in
            let offlineHub = HubApiWrapper(
                downloadBase: folder, endpoint: "file:///EchoFlow-offline-hub"
            )
            let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder, hubApi: offlineHub)
            guard tokenizer.convertTokenToId("<|endoftext|>") != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: folder,
                verbose: false,
                prewarm: true,
                load: true,
                download: false,
                useBackgroundDownloadSession: false
            )
            return try await Session(whisper: WhisperKit(config), tokenizer: tokenizer)
        }
        let transcribe: @Sendable (Session) async throws -> String = { session in
            let results = try await session.whisper.transcribe(
                audioPath: audioPath,
                decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
            )
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cache = SerializedModelCache<Session>()
        let startBefore1 = ProcessInfo.processInfo.systemUptime
        let before1 = try await transcribe(load(directory))
        let elapsedBefore1 = ProcessInfo.processInfo.systemUptime - startBefore1
        let startBefore2 = ProcessInfo.processInfo.systemUptime
        let before2 = try await transcribe(load(directory))
        let elapsedBefore2 = ProcessInfo.processInfo.systemUptime - startBefore2
        // Complete the uncached runs before retaining a Core ML model in the cache;
        // otherwise a large-model benchmark can hold two instances in memory at once.
        let startAfter1 = ProcessInfo.processInfo.systemUptime
        let after1 = try await cache.withModel(at: directory, load: load, operation: transcribe)
        let elapsedAfter1 = ProcessInfo.processInfo.systemUptime - startAfter1
        let startAfter2 = ProcessInfo.processInfo.systemUptime
        let after2 = try await cache.withModel(at: directory, load: load, operation: transcribe)
        let elapsedAfter2 = ProcessInfo.processInfo.systemUptime - startAfter2
        XCTAssertFalse(before1.isEmpty)
        XCTAssertFalse(after1.isEmpty)
        XCTAssertFalse(before2.isEmpty)
        XCTAssertFalse(after2.isEmpty)
        XCTAssertTrue(before1 == after1, "Caching must preserve transcription")
        XCTAssertTrue(before2 == after2, "Caching must preserve transcription")
        print("REAL Whisper baseline load+transcribe (uncached): \(elapsedBefore1)s, \(elapsedBefore2)s")
        print("REAL Whisper cache miss then cache hit (including inference): \(elapsedAfter1)s, \(elapsedAfter2)s")
        print("Transcript equality by corresponding run: \(before1 == after1), \(before2 == after2)")
        print("Core ML warmup, thermal state, and run order affect these numbers; audio may be generated, but inference is real.")
    }
}
