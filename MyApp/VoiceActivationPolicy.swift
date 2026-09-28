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

/// A bounded online trial; foreground transitions never refill the allowance.
struct OnlineVoiceTrialBudget {
    private(set) var startedAt: TimeInterval?
    private(set) var uploads = 0
    mutating func begin(now: TimeInterval) { if startedAt == nil { startedAt = now } }
    func available(now: TimeInterval) -> Bool {
        guard let start = startedAt else { return false }
        return now >= start && now - start < 180 && uploads < 6
    }
    mutating func reserveUpload(now: TimeInterval) -> Bool {
        guard available(now: now) else { return false }
        uploads += 1
        return true
    }
}

/// Capture deadlines use uptime, independent of calendar/time-zone corrections.
struct VoiceCaptureWindow {
    enum Decision: Equatable { case keepListening, finish, discard }
    private let startedAt: TimeInterval
    private var lastVoiceAt: TimeInterval
    private var heardVoice = false
    private var invalidClock = false

    init(now: TimeInterval) {
        startedAt = now
        lastVoiceAt = now
        invalidClock = !now.isFinite || now < 0
    }

    mutating func observeVoice(now: TimeInterval) {
        guard now.isFinite, now >= lastVoiceAt else { invalidClock = true; return }
        heardVoice = true
        lastVoiceAt = now
    }

    func decision(now: TimeInterval, hasTranscript: Bool = false) -> Decision {
        guard !invalidClock, now.isFinite, now >= lastVoiceAt else { return .discard }
        let elapsed = now - startedAt
        let hasSpeech = heardVoice || hasTranscript
        if elapsed >= 20 { return hasSpeech ? .finish : .discard }
        if hasSpeech && now - lastVoiceAt >= 2.4 { return .finish }
        if !hasSpeech && elapsed >= 15 { return .discard }
        return .keepListening
    }
}
