import Foundation

/// Used only by the local microphone-test echo, never by conversational answers.
enum AudioTestPronunciation {
    static func spokenText(_ text: String, language: String) -> String {
        let pattern = #"(?i)^\s*(?:(?:testando|teste|alô|alo|testing|test|hello)\s*[:,]?\s*)?([0-9][0-9.,\s]*[0-9])[.!?]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return text }
        let digits = text[range].compactMap { $0.wholeNumberValue }
        guard (2...32).contains(digits.count) else { return text }
        let words = language == "en-US"
            ? ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            : ["zero", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove"]
        let prefix = language == "en-US" ? "Testing. " : "Testando. "
        let count = digits.map { words[$0] }.joined(separator: ", ")
        return prefix + count.prefix(1).uppercased() + count.dropFirst() + "."
    }
}
