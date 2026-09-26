import Foundation

/// A non-negative range measured in the accessibility API's UTF-16 coordinates.
public struct InsertedTextCorrectionRange: Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init?(location: Int, length: Int) {
        guard location >= 0, length >= 0 else { return nil }
        self.location = location
        self.length = length
    }

    public var upperBound: Int? {
        let (value, overflow) = location.addingReportingOverflow(length)
        return overflow ? nil : value
    }
}

/// The exact selected portion of EchoFlow's inserted string at one moment.
public struct InsertedTextCorrectionCandidate: Equatable, Sendable {
    public let originalText: String
    public let range: InsertedTextCorrectionRange
    public let fieldCharacterCount: Int

    fileprivate init(originalText: String, range: InsertedTextCorrectionRange, fieldCharacterCount: Int) {
        self.originalText = originalText
        self.range = range
        self.fieldCharacterCount = fieldCharacterCount
    }
}

/// Restricts accessibility text reads to the exact range EchoFlow inserted.
/// It never reads a whole text field or derives text from outside that range.
public struct InsertedTextCorrectionScope: Sendable {
    public let insertedText: String
    public let insertionLocation: Int
    private let insertedUTF16Length: Int

    public init?(insertedText: String, insertionLocation: Int) {
        let length = insertedText.utf16.count
        guard insertionLocation >= 0, length > 0 else { return nil }
        let (_, overflow) = insertionLocation.addingReportingOverflow(length)
        guard !overflow else { return nil }
        self.insertedText = insertedText
        self.insertionLocation = insertionLocation
        self.insertedUTF16Length = length
    }

    /// Captures a non-empty selection wholly inside EchoFlow's original insertion.
    public func candidate(
        for selection: InsertedTextCorrectionRange,
        fieldCharacterCount: Int
    ) -> InsertedTextCorrectionCandidate? {
        let (insertedEnd, endOverflow) = insertionLocation.addingReportingOverflow(insertedUTF16Length)
        guard !endOverflow,
              fieldCharacterCount >= 0,
              let selectionEnd = selection.upperBound,
              selection.length > 0,
              selection.location >= insertionLocation,
              selectionEnd <= insertedEnd,
              selectionEnd <= fieldCharacterCount else {
            return nil
        }

        let localRange = NSRange(
            location: selection.location - insertionLocation,
            length: selection.length
        )
        let source = insertedText as NSString
        guard NSMaxRange(localRange) <= source.length else { return nil }
        return InsertedTextCorrectionCandidate(
            originalText: source.substring(with: localRange),
            range: selection,
            fieldCharacterCount: fieldCharacterCount
        )
    }

    /// Accepts a replacement only if the field's length delta and resulting caret
    /// agree exactly with replacement of the previously selected inserted range.
    public func replacementRange(
        for candidate: InsertedTextCorrectionCandidate,
        currentFieldCharacterCount: Int,
        caretLocation: Int
    ) -> InsertedTextCorrectionRange? {
        guard currentFieldCharacterCount >= 0,
              caretLocation >= 0 else { return nil }
        let (delta, deltaOverflow) = currentFieldCharacterCount
            .subtractingReportingOverflow(candidate.fieldCharacterCount)
        guard !deltaOverflow else { return nil }
        let (replacementLength, lengthOverflow) = candidate.range.length.addingReportingOverflow(delta)
        guard !lengthOverflow, replacementLength > 0,
              let replacement = InsertedTextCorrectionRange(
                location: candidate.range.location,
                length: replacementLength
              ),
              replacement.upperBound == caretLocation,
              caretLocation <= currentFieldCharacterCount else {
            return nil
        }
        return replacement
    }
}
