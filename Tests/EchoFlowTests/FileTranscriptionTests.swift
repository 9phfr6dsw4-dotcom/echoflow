import XCTest
@testable import EchoFlowCore

final class FileTranscriptionTests: XCTestCase {
    func testSupportedFileTypes() {
        XCTAssertTrue(FileTranscriptionSupport.isSupported(URL(fileURLWithPath: "/tmp/talk.MP3")))
        XCTAssertTrue(FileTranscriptionSupport.isSupported(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertTrue(FileTranscriptionSupport.isSupported(URL(fileURLWithPath: "/tmp/song.flac")))
        XCTAssertFalse(FileTranscriptionSupport.isSupported(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(FileTranscriptionSupport.isSupported(URL(fileURLWithPath: "/tmp/noextension")))
    }

    func testSRTTimestamps() {
        XCTAssertEqual(SubtitleBuilder.timestamp(0), "00:00:00,000")
        XCTAssertEqual(SubtitleBuilder.timestamp(3723.456), "01:02:03,456")
        XCTAssertEqual(SubtitleBuilder.timestamp(59.9996), "00:01:00,000")
        XCTAssertEqual(SubtitleBuilder.timestamp(-5), "00:00:00,000")
    }

    func testProgressLabel() {
        XCTAssertEqual(SubtitleBuilder.progressLabel(fraction: 0.5, duration: 120), "Transcribing… 1:00 / 2:00")
        XCTAssertEqual(SubtitleBuilder.clock(3723), "1:02:03")
        XCTAssertEqual(SubtitleBuilder.clock(222), "3:42")
    }

    func testTokensSplitAtPausesAndFormatAsSRT() {
        let cues = SubtitleBuilder.cues(from: [
            TimedTextPiece(text: " Hello", start: 0, end: 0.4),
            TimedTextPiece(text: " world", start: 0.4, end: 0.8),
            TimedTextPiece(text: ".", start: 0.8, end: 0.9),
            TimedTextPiece(text: " Next", start: 3.0, end: 3.4),
            TimedTextPiece(text: " line", start: 3.4, end: 3.8)
        ])
        XCTAssertEqual(cues, [
            SubtitleCue(index: 1, start: 0, end: 0.9, text: "Hello world."),
            SubtitleCue(index: 2, start: 3.0, end: 3.8, text: "Next line")
        ])
        XCTAssertEqual(
            SubtitleBuilder.srt(from: cues),
            "1\n00:00:00,000 --> 00:00:00,900\nHello world.\n\n2\n00:00:03,000 --> 00:00:03,800\nNext line\n"
        )
    }

    func testLongSpeechSplitsAtSixSeconds() {
        let pieces = (0..<20).map { index in
            TimedTextPiece(text: " word", start: Double(index) * 0.5, end: Double(index + 1) * 0.5)
        }
        let cues = SubtitleBuilder.cues(from: pieces)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, Array(repeating: "word", count: 12).joined(separator: " "))
        XCTAssertEqual(cues[1].start, 6.0)
        XCTAssertEqual(cues[1].text, Array(repeating: "word", count: 8).joined(separator: " "))
    }

    func testNeverSplitsInsideAWord() {
        let cues = SubtitleBuilder.cues(from: [
            TimedTextPiece(text: " Trans", start: 0, end: 3.0),
            TimedTextPiece(text: "cription", start: 3.0, end: 6.5),
            TimedTextPiece(text: " done", start: 6.5, end: 7.0)
        ])
        XCTAssertEqual(cues.map(\.text), ["Transcription", "done"])
        XCTAssertEqual(cues[0].end, 6.5)
    }

    func testWhisperSegmentsBecomeOneCueEach() {
        let cues = SubtitleBuilder.cues(from: [
            TimedTextPiece(text: " First segment.", start: 0, end: 8),
            TimedTextPiece(text: " Second.", start: 8, end: 10)
        ])
        XCTAssertEqual(cues.map(\.text), ["First segment.", "Second."])
        XCTAssertEqual(cues.map(\.start), [0, 8])
    }

    func testTrailingSpacesAlsoMarkWordBoundaries() {
        let cues = SubtitleBuilder.cues(from: [
            TimedTextPiece(text: "Hi ", start: 0, end: 0.4),
            TimedTextPiece(text: "there ", start: 0.4, end: 0.8),
            TimedTextPiece(text: "Next ", start: 3.0, end: 3.4),
            TimedTextPiece(text: "one", start: 3.4, end: 3.8)
        ])
        XCTAssertEqual(cues.map(\.text), ["Hi there", "Next one"])
        XCTAssertEqual(cues.map(\.start), [0, 3.0])
    }

    func testNoTimingsMeansNoCues() {
        XCTAssertTrue(SubtitleBuilder.cues(from: []).isEmpty)
    }
}
