import XCTest
@testable import EchoFlowCore

final class KeyboardTextEventPolicyTests: XCTestCase {
    func testSplitsLongTextIntoBoundedUnicodeEventChunks() {
        let input = String(repeating: "a", count: 45)
        let chunks = KeyboardTextEventPolicy.unicodeChunks(for: input)

        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        XCTAssertEqual(chunks.flatMap { $0 }, Array(input.utf16))
    }

    func testDoesNotSplitSurrogatePairsAcrossEvents() {
        let input = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = KeyboardTextEventPolicy.unicodeChunks(for: input)

        // The pair would straddle the 20-unit boundary, so the first event stops before it
        // and the pair travels intact with the remaining text.
        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertEqual(chunks.flatMap { $0 }, Array(input.utf16))
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, KeyboardTextEventPolicy.maximumUTF16CodeUnitsPerEvent)
            XCTAssertFalse((0xD800...0xDBFF).contains(chunk.last ?? 0), "Chunk ends with an unpaired high surrogate")
            XCTAssertFalse((0xDC00...0xDFFF).contains(chunk.first ?? 0), "Chunk starts with an unpaired low surrogate")
        }
    }

    func testEmptyTextProducesNoKeyboardEvents() {
        XCTAssertTrue(KeyboardTextEventPolicy.unicodeChunks(for: "").isEmpty)
    }
}
