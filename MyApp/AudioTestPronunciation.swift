import Foundation

/// Normalizes only an explicit microphone-test count; never rewrites ordinary numbers.
enum AudioTestPronunciation {
    static func spokenText(_ text: String, language: String) -> String {
        let pattern = #"(?i)^\s*(testando|teste|alô|alo|testing|test|hello)\s*[:,]?\s*1[., ]*2[., ]*3[., ]*4[.!?]?\s*$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return text }
        return language == "en-US" ? "Testing. One, two, three, four." : "Testando. Um, dois, três, quatro."
    }
}
