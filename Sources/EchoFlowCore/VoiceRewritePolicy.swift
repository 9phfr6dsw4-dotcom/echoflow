import Foundation

public struct VoiceRewriteRequest: Codable, Equatable, Sendable {
    public let selectedText: String
    public let instruction: String

    public init(selectedText: String, instruction: String) {
        self.selectedText = selectedText
        self.instruction = instruction
    }
}

public enum VoiceRewritePolicy {
    public static let maximumInputCharacters = 6_000
    public static let maximumInstructionCharacters = 2_000
    public static let maximumOutputCharacters = 12_000

    public static func request(selectedText: String, instruction: String) -> VoiceRewriteRequest? {
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedText.count <= maximumInputCharacters,
              instruction.count <= maximumInstructionCharacters else {
            return nil
        }
        return VoiceRewriteRequest(selectedText: selectedText, instruction: instruction)
    }

    public static func validOutput(_ candidate: String?) -> String? {
        guard let candidate,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.count <= maximumOutputCharacters else {
            return nil
        }
        return candidate
    }
}
