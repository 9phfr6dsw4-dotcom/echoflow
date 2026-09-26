import Foundation
import XCTest
@testable import EchoFlowCore

final class TranscriptTextCleanupTests: XCTestCase {
    func testRemovesFillerWordsWithoutChangingWordsThatContainThem() {
        var settings = TranscriptTextCleanupSettings()
        settings.removeFillerWords = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("Um, I, like, really want apples, uh.", settings: settings),
            "I really want apples."
        )
        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("The summer concert is in Uhura's honor.", settings: settings),
            "The summer concert is in Uhura's honor."
        )
    }

    func testLikeRemovesOnlyAsAnExplicitDiscourseFiller() {
        var settings = TranscriptTextCleanupSettings()
        settings.removeFillerWords = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("Like, I, like, really want this.", settings: settings),
            "I really want this."
        )
        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("I like apples and it looks like a pear.", settings: settings),
            "I like apples and it looks like a pear."
        )
    }

    func testRemovesRepeatedFalseStartsButLeavesUnrepeatedText() {
        var settings = TranscriptTextCleanupSettings()
        settings.removeFalseStarts = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("I, I think we should— we should go now.", settings: settings),
            "I think we should go now."
        )
        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("We should go now.", settings: settings),
            "We should go now."
        )
    }

    func testConvertsCardinalAndScaledSpokenNumbers() {
        var settings = TranscriptTextCleanupSettings()
        settings.convertSpokenNumbersToDigits = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply(
                "I need twenty-one notebooks, one hundred and five pens, and two thousand three tickets.",
                settings: settings
            ),
            "I need 21 notebooks, 105 pens, and 2003 tickets."
        )
    }

    func testConvertsDecimalAndNegativeSpokenNumbersAndPreservesPunctuation() {
        var settings = TranscriptTextCleanupSettings()
        settings.convertSpokenNumbersToDigits = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("The temperature is negative five point two degrees.", settings: settings),
            "The temperature is -5.2 degrees."
        )
    }

    func testConvertsSpokenOrdinalNumbers() {
        var settings = TranscriptTextCleanupSettings()
        settings.convertSpokenNumbersToDigits = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply(
                "Read the twenty-first chapter, then the eleventh and one hundredth pages.",
                settings: settings
            ),
            "Read the 21st chapter, then the 11th and 100th pages."
        )
    }

    func testNumberConversionDoesNotSwallowAnIncompleteDecimalOrOrdinaryWords() {
        var settings = TranscriptTextCleanupSettings()
        settings.convertSpokenNumbersToDigits = true

        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply("One point at a time, one of my favorite books.", settings: settings),
            "1 point at a time, 1 of my favorite books."
        )
    }

    func testEachDeterministicCleanupSwitchIsIndependent() {
        let original = "Um, I, like, I have twenty-one ideas."
        XCTAssertEqual(TranscriptTextCleanupPolicy.apply(original, settings: TranscriptTextCleanupSettings()), original)

        var fillersOnly = TranscriptTextCleanupSettings()
        fillersOnly.removeFillerWords = true
        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply(original, settings: fillersOnly),
            "I, I have twenty-one ideas."
        )

        var numbersOnly = TranscriptTextCleanupSettings()
        numbersOnly.convertSpokenNumbersToDigits = true
        XCTAssertEqual(
            TranscriptTextCleanupPolicy.apply(original, settings: numbersOnly),
            "Um, I, like, I have 21 ideas."
        )
    }

    func testPerApplicationStyleDefaultsAndTerminalOptOut() {
        let settings = TranscriptTextCleanupSettings()
        XCTAssertEqual(settings.style(forBundleIdentifier: "com.apple.MobileSMS"), .casual)
        XCTAssertEqual(settings.style(forBundleIdentifier: "md.obsidian"), .clean)
        XCTAssertEqual(settings.style(forBundleIdentifier: "com.anthropic.claudefordesktop"), .clean)
        XCTAssertEqual(settings.style(forBundleIdentifier: "com.apple.Terminal"), .unchanged)
        XCTAssertEqual(settings.style(forBundleIdentifier: "com.example.editor"), .clean)
        XCTAssertEqual(settings.style(forBundleIdentifier: nil), .clean)
    }

    func testApplicationProfilesAreCaseInsensitiveAndCodable() throws {
        var settings = TranscriptTextCleanupSettings()
        settings.setStyle(.casual, for: AppTextCleanupProfile(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            style: .clean
        ))

        XCTAssertEqual(settings.style(forBundleIdentifier: "COM.EXAMPLE.EDITOR"), .casual)
        let decoded = try JSONDecoder().decode(
            TranscriptTextCleanupSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testNoChangesProfileBypassesEveryBatchTwoTransformation() {
        let settings = TranscriptTextCleanupSettings(
            removeFillerWords: true,
            removeFalseStarts: true,
            convertSpokenNumbersToDigits: true,
            aiCleanupEnabled: true
        )
        let original = "Um, I, like, I have twenty-one ideas."

        let plan = TranscriptTextCleanupPolicy.plan(
            original,
            settings: settings,
            targetBundleIdentifier: "com.apple.Terminal"
        )

        XCTAssertEqual(plan.text, original)
        XCTAssertNil(plan.aiStyle)
    }

    func testEnabledTextRulesRunWithoutAIAndAppStyleSelectsAIOnlyWhenEnabled() {
        var settings = TranscriptTextCleanupSettings(removeFillerWords: true, aiCleanupEnabled: false)
        let input = "Um, hello"

        let rulesOnly = TranscriptTextCleanupPolicy.plan(
            input,
            settings: settings,
            targetBundleIdentifier: "com.apple.MobileSMS"
        )
        XCTAssertEqual(rulesOnly.text, "hello")
        XCTAssertNil(rulesOnly.aiStyle)

        settings.aiCleanupEnabled = true
        let withAI = TranscriptTextCleanupPolicy.plan(
            input,
            settings: settings,
            targetBundleIdentifier: "com.apple.MobileSMS"
        )
        XCTAssertEqual(withAI.text, "hello")
        XCTAssertEqual(withAI.aiStyle, .casual)
    }

    func testAIFallbackReturnsRawTranscriptInsteadOfRuleCleanedText() {
        let settings = TranscriptTextCleanupSettings(removeFillerWords: true, aiCleanupEnabled: true)
        let input = "Um, hello"
        let plan = TranscriptTextCleanupPolicy.plan(
            input,
            settings: settings,
            targetBundleIdentifier: "com.apple.MobileSMS"
        )

        XCTAssertEqual(plan.text, "hello")
        XCTAssertEqual(plan.rawText, input)
        XCTAssertEqual(
            TranscriptAIOutputPolicy.deliveredText(nil, preparedText: plan.text, fallbackText: plan.rawText),
            input
        )
        XCTAssertEqual(
            TranscriptAIOutputPolicy.deliveredText("  ", preparedText: plan.text, fallbackText: plan.rawText),
            input
        )
        let excessiveCandidate = String(repeating: "extra ", count: 200)
        XCTAssertEqual(
            TranscriptAIOutputPolicy.deliveredText(excessiveCandidate, preparedText: "short", fallbackText: input),
            input
        )
    }

    func testAIOutputPolicyUsesPreAITextWhenResponseIsEmptyOrUnreasonablyLong() {
        XCTAssertEqual(
            TranscriptAIOutputPolicy.acceptedCandidate("  Hello, world!  ", original: "hello world"),
            "Hello, world!"
        )
        XCTAssertNil(TranscriptAIOutputPolicy.acceptedCandidate("  \n", original: "hello"))
        XCTAssertNil(TranscriptAIOutputPolicy.acceptedCandidate(String(repeating: "extra ", count: 200), original: "short"))
    }
}
