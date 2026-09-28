import Foundation

/// Pure routing policy: ambient speech never reaches the conversation endpoint.
struct VoiceActivationPolicy {
    enum Result: Equatable { case ignore, acknowledge, request(String) }
    private(set) var awaitingRequest = false
    private(set) var failures = 0
    var retrySeconds: Double { failures == 0 ? 0.6 : min(30, pow(2, Double(failures - 1))) }

    mutating func consume(_ text: String) -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { awaitingRequest = false; return .ignore }
        let pattern = #"(?i)\btars\b[\s,.:;!?—-]*"#
        let range = text.range(of: pattern, options: .regularExpression)
        guard awaitingRequest || range != nil else { return .ignore }
        let request = range.map { String(text[$0.upperBound...]) } ?? text
        awaitingRequest = request.isEmpty
        failures = 0
        return request.isEmpty ? .acknowledge : .request(request)
    }
    mutating func failed() { failures = min(6, failures + 1); awaitingRequest = false }
    mutating func reset() { failures = 0; awaitingRequest = false }
}
