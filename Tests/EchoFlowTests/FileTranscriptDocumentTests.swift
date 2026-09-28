import Foundation
import XCTest
@testable import EchoFlowCore

final class FileTranscriptDocumentTests: XCTestCase {
    private func words(_ spec: [(String, Double)], length: Double = 0.4) -> [TimedTextPiece] {
        spec.map { TimedTextPiece(text: $0.0, start: $0.1, end: $0.1 + length) }
    }

    func testSubWordTokensJoinIntoWordsAndSpeakersChangeOnlyBetweenWords() {
        let pieces = [
            TimedTextPiece(text: " Hel", start: 0.0, end: 0.2),
            TimedTextPiece(text: "lo", start: 0.2, end: 0.5),
            TimedTextPiece(text: " there", start: 0.5, end: 0.9),
            TimedTextPiece(text: ".", start: 0.9, end: 1.0),
            TimedTextPiece(text: " Hi", start: 1.2, end: 1.5),
            TimedTextPiece(text: " back", start: 1.5, end: 1.9),
            TimedTextPiece(text: ".", start: 1.9, end: 2.0)
        ]
        let turns = [
            SpeakerTurn(speakerID: "S0", start: 0.0, end: 1.1),
            SpeakerTurn(speakerID: "S1", start: 1.1, end: 2.0)
        ]
        let blocks = TranscriptBlockBuilder.blocks(from: pieces, speakerTurns: turns)
        XCTAssertEqual(blocks, [
            TranscriptBlock(start: 0.0, end: 1.0, speakerID: "S0", text: "Hello there."),
            TranscriptBlock(start: 1.2, end: 2.0, speakerID: "S1", text: "Hi back.")
        ])
    }

    func testWordInAPauseTakesTheNearestSpeakerAndShortFlipsAreSmoothed() {
        let pieces = words([(" one", 0), (" two", 1), (" three", 2), (" four", 10)])
        let turns = [
            SpeakerTurn(speakerID: "A", start: 0, end: 0.9),
            SpeakerTurn(speakerID: "B", start: 1.0, end: 1.3),
            SpeakerTurn(speakerID: "A", start: 2.0, end: 3.0),
            SpeakerTurn(speakerID: "B", start: 9.0, end: 9.5)
        ]
        let blocks = TranscriptBlockBuilder.blocks(from: pieces, speakerTurns: turns)
        XCTAssertEqual(blocks.map(\.speakerID), ["A", "B"])
        XCTAssertEqual(blocks.map(\.text), ["one two three", "four"])
    }

    func testSpeakerChangesMoveToTheNearestSentenceEnd() {
        let late = TranscriptBlockBuilder.blocks(
            from: [
                TimedTextPiece(text: " Ready?", start: 0.0, end: 0.4),
                TimedTextPiece(text: " Well,", start: 0.5, end: 0.7),
                TimedTextPiece(text: " I", start: 0.7, end: 0.8),
                TimedTextPiece(text: " agree", start: 0.8, end: 1.2),
                TimedTextPiece(text: " because", start: 1.5, end: 1.8),
                TimedTextPiece(text: " yes.", start: 1.8, end: 2.2)
            ],
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 1.45),
                SpeakerTurn(speakerID: "B", start: 1.45, end: 3)
            ]
        )
        XCTAssertEqual(late.map(\.speakerID), ["A", "B"])
        XCTAssertEqual(late.map(\.text), ["Ready?", "Well, I agree because yes."])

        let early = TranscriptBlockBuilder.blocks(
            from: [
                TimedTextPiece(text: " As", start: 0.0, end: 0.3),
                TimedTextPiece(text: " he", start: 0.3, end: 0.6),
                TimedTextPiece(text: " put", start: 1.0, end: 1.3),
                TimedTextPiece(text: " it.", start: 1.3, end: 1.6),
                TimedTextPiece(text: " Right.", start: 2.0, end: 2.3),
                TimedTextPiece(text: " Thanks.", start: 2.4, end: 2.8)
            ],
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 0.8),
                SpeakerTurn(speakerID: "B", start: 0.8, end: 3)
            ]
        )
        XCTAssertEqual(early.map(\.text), ["As he put it.", "Right. Thanks."])

        let interjection = TranscriptBlockBuilder.blocks(
            from: [
                TimedTextPiece(text: " Go", start: 0.0, end: 0.3),
                TimedTextPiece(text: " on.", start: 0.3, end: 0.6),
                TimedTextPiece(text: " Yes.", start: 0.8, end: 1.2),
                TimedTextPiece(text: " Then", start: 1.4, end: 1.7),
                TimedTextPiece(text: " done.", start: 1.7, end: 2.0)
            ],
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 0.7),
                SpeakerTurn(speakerID: "B", start: 0.7, end: 1.3),
                SpeakerTurn(speakerID: "A", start: 1.3, end: 2.1)
            ]
        )
        XCTAssertEqual(interjection.map(\.speakerID), ["A", "B", "A"])
        XCTAssertEqual(interjection.map(\.text), ["Go on.", "Yes.", "Then done."])
    }

    func testShortMidSentenceBlipsGoBackButRealInterruptionsStay() {
        let blip = TranscriptBlockBuilder.blocks(
            from: words([
                (" Well", 0.0), (" I", 0.4), (" think", 0.8), (" there", 1.2),
                (" was", 1.6), (" a", 2.0), (" strong", 2.4), (" sense", 2.8),
                (" in", 3.2), (" Europe.", 3.6)
            ]),
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 1.6),
                SpeakerTurn(speakerID: "B", start: 1.6, end: 3.2),
                SpeakerTurn(speakerID: "A", start: 3.2, end: 4.0)
            ]
        )
        XCTAssertEqual(blip.map(\.speakerID), ["A"])
        XCTAssertEqual(blip.map(\.text), ["Well I think there was a strong sense in Europe."])

        let interruption = TranscriptBlockBuilder.blocks(
            from: words([
                (" It", 0.0), (" matters", 0.4), (" and", 0.8),
                (" Fine.", 1.2), (" Say", 1.6), (" more?", 2.0),
                (" Yes,", 2.4), (" it", 2.8), (" does.", 3.2)
            ]),
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 1.2),
                SpeakerTurn(speakerID: "B", start: 1.2, end: 2.4),
                SpeakerTurn(speakerID: "A", start: 2.4, end: 3.6)
            ]
        )
        XCTAssertEqual(interruption.map(\.speakerID), ["A", "B", "A"])
        XCTAssertEqual(interruption.map(\.text), ["It matters and", "Fine. Say more?", "Yes, it does."])
    }

    func testACutOffSentenceKeepsTheNewSpeakersWords() {
        let blocks = TranscriptBlockBuilder.blocks(
            from: words([
                (" We", 0.0), (" know", 0.4), (" it", 0.8), (" through", 1.2), (" the", 1.6),
                (" land", 2.0), (" and", 2.4),
                (" so", 2.8), (" I", 3.2), (" think", 3.6), (" that's", 4.0), (" right.", 4.4),
                (" The", 4.8), (" British", 5.2), (" agree.", 5.6)
            ]),
            speakerTurns: [
                SpeakerTurn(speakerID: "A", start: 0, end: 2.8),
                SpeakerTurn(speakerID: "B", start: 2.8, end: 6.0)
            ]
        )
        XCTAssertEqual(blocks.map(\.speakerID), ["A", "B"])
        XCTAssertEqual(blocks.map(\.text), ["We know it through the land and", "so I think that's right. The British agree."])
    }

    func testParagraphsWithoutSpeakersBreakAtASentenceAfterThirtySeconds() {
        var pieces: [TimedTextPiece] = []
        for second in 0..<70 {
            let text = second % 10 == 9 ? " end." : " word"
            pieces.append(TimedTextPiece(text: text, start: Double(second), end: Double(second) + 0.5))
        }
        let blocks = TranscriptBlockBuilder.blocks(from: pieces, speakerTurns: [])
        XCTAssertEqual(blocks.map(\.start), [0, 30, 60])
        XCTAssertEqual(blocks.map(\.speakerID), [nil, nil, nil])
        XCTAssertTrue(blocks[0].text.hasSuffix("end."))
    }

    func testSpeakerNamesFollowFirstAppearanceAndCustomNames() {
        var document = FileTranscriptDocument(
            title: "  ",
            sourceFileName: "Talk.final.mp3",
            duration: 1693,
            engineName: "Parakeet",
            hasTimings: true,
            blocks: [
                TranscriptBlock(start: 0, end: 5, speakerID: "B", text: "Hello."),
                TranscriptBlock(start: 94, end: 99, speakerID: "A", text: "Well, I think so."),
                TranscriptBlock(start: 136, end: 140, speakerID: "B", text: "Right.")
            ],
            subtitleSRT: ""
        )
        XCTAssertEqual(document.displayTitle, "Talk.final")
        XCTAssertEqual(document.speakerIDs, ["B", "A"])
        XCTAssertEqual(document.speakerName(for: "B"), "Speaker 1")
        XCTAssertEqual(document.speakerName(for: "A"), "Speaker 2")
        XCTAssertNil(document.speakerName(for: nil))
        document.speakerNames["A"] = " Anne Janowitz "
        document.speakerNames["B"] = "   "
        XCTAssertEqual(document.speakerName(for: "A"), "Anne Janowitz")
        XCTAssertEqual(document.speakerName(for: "B"), "Speaker 1")
    }

    func testPlainTextAndMarkdownLayouts() {
        var document = FileTranscriptDocument(
            title: "The French Revolution",
            sourceFileName: "InOurTime.mp3",
            duration: 1693,
            engineName: "Parakeet",
            hasTimings: true,
            blocks: [
                TranscriptBlock(start: 0.36, end: 93.6, speakerID: "S0", text: "Thanks for downloading."),
                TranscriptBlock(start: 94.0, end: 136.5, speakerID: "S1", text: "Well, I think so.")
            ],
            speakerNames: ["S0": "Melvyn Bragg"],
            subtitleSRT: ""
        )
        XCTAssertEqual(
            FileTranscriptExporter.plainText(document, dateText: "Sep 27, 2026"),
            """
            The French Revolution
            InOurTime.mp3 · 28:13 · Parakeet · Sep 27, 2026

            [00:00:00] Melvyn Bragg
            Thanks for downloading.

            [00:01:34] Speaker 2
            Well, I think so.

            """
        )
        XCTAssertEqual(
            FileTranscriptExporter.markdown(document, dateText: "Sep 27, 2026"),
            """
            # The French Revolution

            *InOurTime.mp3 · 28:13 · Parakeet · Sep 27, 2026*

            **[00:00:00] Melvyn Bragg**

            Thanks for downloading.

            **[00:01:34] Speaker 2**

            Well, I think so.

            """
        )
        document.hasTimings = false
        document.blocks = [TranscriptBlock(start: 0, end: 0, speakerID: nil, text: "No timings here.")]
        XCTAssertEqual(
            FileTranscriptExporter.plainText(document, dateText: "Sep 27, 2026"),
            "The French Revolution\nInOurTime.mp3 · 28:13 · Parakeet · Sep 27, 2026\n\nNo timings here.\n"
        )
    }

    func testTimestampsAndSuggestedFileName() {
        XCTAssertEqual(FileTranscriptExporter.timestamp(0), "00:00:00")
        XCTAssertEqual(FileTranscriptExporter.timestamp(94.9), "00:01:34")
        XCTAssertEqual(FileTranscriptExporter.timestamp(3723), "01:02:03")
        let document = FileTranscriptDocument(
            title: "Q&A: 2026/09 recap.",
            sourceFileName: "a.mp3",
            duration: 0,
            engineName: "Whisper",
            hasTimings: false,
            blocks: [],
            subtitleSRT: ""
        )
        XCTAssertEqual(FileTranscriptExporter.suggestedFileName(for: document), "Q&A- 2026-09 recap")
    }

    func testTranscriptNumberStyle() {
        let cases: [(String, String)] = [
            ("In seventeen eighty nine the Bastille was stormed.", "In 1789 the Bastille was stormed."),
            ("the sixteen forty nine revolution and eighteen fifteen", "the 1649 revolution and 1815"),
            ("the seventeen seventies and seventeen eighties", "the 1770s and 1780s"),
            ("until the eighteen thirties, in nineteen oh five", "until the 1830s, in 1905"),
            ("King Louis the Sixteenth was put under guard", "King Louis XVI was put under guard"),
            ("In the First World War", "In the First World War"),
            ("one of the most, the first time, three or four years", "one of the most, the first time, three or four years"),
            ("armies of sixty or seventy thousand, six hundred thousand strong", "armies of 60 or 70,000, 600,000 strong"),
            ("forty years, ten, fifteen years before", "40 years, 10, 15 years before"),
            ("the nineteenth century and the twenty-first chapter", "the 19th century and the 21st chapter"),
            ("at eleven thirty we met, one two three", "at eleven thirty we met, one two three"),
            ("one hundred and five pens, two thousand three tickets", "105 pens, 2003 tickets"),
            ("a forty-year-old and a hundred years", "a 40-year-old and a hundred years")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(FileTranscriptNumberStyle.apply(input), expected, input)
        }
    }

    func testComposerCleansParagraphsAndSubtitles() {
        var cleanup = TranscriptTextCleanupSettings()
        cleanup.removeFillerWords = true
        cleanup.convertSpokenNumbersToDigits = true
        let pieces = [
            TimedTextPiece(text: " Um,", start: 0, end: 0.3),
            TimedTextPiece(text: " in", start: 0.4, end: 0.6),
            TimedTextPiece(text: " seventeen", start: 0.6, end: 1.0),
            TimedTextPiece(text: " eighty", start: 1.0, end: 1.3),
            TimedTextPiece(text: " nine.", start: 1.3, end: 1.8),
            TimedTextPiece(text: " Uh.", start: 4.0, end: 4.3)
        ]
        let composition = FileTranscriptComposer.compose(
            text: "Um, in seventeen eighty nine. Uh.",
            pieces: pieces,
            speakerTurns: [],
            cleanup: cleanup
        )
        XCTAssertTrue(composition.hasTimings)
        XCTAssertEqual(composition.blocks, [TranscriptBlock(start: 0, end: 4.3, speakerID: nil, text: "In 1789.")])
        XCTAssertEqual(composition.subtitleSRT, "1\n00:00:00,000 --> 00:00:01,800\nIn 1789.\n")

        let untimed = FileTranscriptComposer.compose(text: "  Plain   text. ", pieces: [], speakerTurns: [], cleanup: cleanup)
        XCTAssertFalse(untimed.hasTimings)
        XCTAssertEqual(untimed.blocks, [TranscriptBlock(start: 0, end: 0, speakerID: nil, text: "Plain text.")])
        XCTAssertEqual(untimed.subtitleSRT, "")
    }

    func testFillersAreRemovedBeforeFalseStartsAndSentenceCapitalsReturn() {
        var cleanup = TranscriptTextCleanupSettings()
        cleanup.removeFillerWords = true
        cleanup.removeFalseStarts = true
        XCTAssertEqual(
            FileTranscriptComposer.cleanedText("I agree with uh with that, to um to just wipe it in in in in this sense.", settings: cleanup),
            "I agree with that, to just wipe it in this sense."
        )
        XCTAssertEqual(
            FileTranscriptComposer.cleanedText("Right. uh how do you think? um, so it goes. the idea that... members of it", settings: cleanup),
            "Right. How do you think? So it goes. The idea that... members of it"
        )
        XCTAssertEqual(
            FileTranscriptComposer.cleanedText("the idea. uh with with it", settings: TranscriptTextCleanupSettings()),
            "the idea. uh with with it"
        )
    }

    func testPolishKeepsSmallEditsAndRejectsRewrites() {
        let original = "so when we think about the impact of the french revolution on english culture we tend to think of wordsworth"
        XCTAssertEqual(
            FileTranscriptPolishPolicy.acceptedText(
                "<transcript>So when we think about the impact of the French Revolution on English culture, we tend to think of Wordsworth.</transcript>",
                original: original
            ),
            "So when we think about the impact of the French Revolution on English culture, we tend to think of Wordsworth."
        )
        XCTAssertNil(FileTranscriptPolishPolicy.acceptedText(
            "The French Revolution deeply shaped English culture, as Wordsworth's poetry shows.",
            original: original
        ))
        XCTAssertEqual(
            FileTranscriptPolishPolicy.acceptedText("“Hello there, friend.”", original: "hello there friend"),
            "Hello there, friend."
        )
        XCTAssertNil(FileTranscriptPolishPolicy.acceptedText("   ", original: "hello there friend"))
        XCTAssertEqual(FileTranscriptPolishPolicy.wordDistance(["a", "b", "c"], ["a", "x", "c", "d"], limit: 5), 2)
        XCTAssertEqual(FileTranscriptPolishPolicy.wordDistance(["a"], [], limit: 5), 1)
    }

    func testStoreSavesListsPrunesAndDeletesOnlyItsOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EchoFlowFileStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileTranscriptStore(applicationSupportDirectory: root)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let recent = FileTranscriptDocument(
            title: "Recent", sourceFileName: "r.mp3", duration: 10, engineName: "Parakeet",
            createdAt: now.addingTimeInterval(-3600), hasTimings: true,
            blocks: [TranscriptBlock(start: 0, end: 1, speakerID: "S0", text: "Hi.")],
            speakerNames: ["S0": "Ann"], subtitleSRT: "1\n00:00:00,000 --> 00:00:01,000\nHi.\n"
        )
        let old = FileTranscriptDocument(
            title: "Old", sourceFileName: "o.mp3", duration: 10, engineName: "Whisper",
            createdAt: now.addingTimeInterval(-40 * 24 * 3600), hasTimings: false,
            blocks: [], subtitleSRT: ""
        )
        try store.save(old)
        try store.save(recent)
        let otherFile = store.directoryURL.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: otherFile)

        XCTAssertEqual(store.documents(), [recent, old])
        XCTAssertEqual(try store.prune(retention: .forever, now: now), 0)
        XCTAssertEqual(try store.prune(retention: .thirtyDays, now: now), 1)
        XCTAssertEqual(store.documents(), [recent])

        try store.delete(id: recent.id)
        XCTAssertEqual(store.documents(), [])
        try store.save(recent)
        try store.deleteAll()
        XCTAssertEqual(store.documents(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path))
    }
}
