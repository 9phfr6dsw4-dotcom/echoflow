import Foundation

public enum KeyboardTextEventPolicy {
    public static let maximumUTF16CodeUnitsPerEvent = 20

    /// Splits Unicode text into keyboard-event-sized UTF-16 chunks without dividing surrogate pairs.
    public static func unicodeChunks(for text: String) -> [[UInt16]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maximumUTF16CodeUnitsPerEvent, units.count)
            if end < units.count,
               isHighSurrogate(units[end - 1]),
               isLowSurrogate(units[end]) {
                end -= 1
            }
            chunks.append(Array(units[start..<end]))
            start = end
        }
        return chunks
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private static func isLowSurrogate(_ unit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }
}
