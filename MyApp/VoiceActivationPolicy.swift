import Foundation

/// Routes speech while TARS is awake. Wake persists until an explicit sleep command.
struct VoiceActivationPolicy {
    enum Result: Equatable { case ignore, acknowledge, continueListening, sleep, request(String) }

    private(set) var awaitingRequest = false
    private(set) var failures = 0
    private(set) var awake = false

    // Compatibility with the existing audio controller:
    // an awake TARS always accepts conversational follow-up.
    func acceptsFollowUp(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        awake
    }

    // Finishing a reply must never put TARS back to sleep.
    mutating func replyFinished(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    }

    var retrySeconds: Double {
        failures == 0 ? 0.6 : min(30, pow(2, Double(failures - 1)))
    }

    mutating func consume(
        _ text: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Silence never changes awake/asleep state.
        guard !text.isEmpty else { return .ignore }

        let sleepPattern =
            #"(?i)^\s*(?:tars[\s,.:;!?—-]*)?(?:go\s+to\s+sleep|sleep|dorme|pode\s+dormir|vai\s+dormir|fica\s+quieto|fique\s+quieto)\s*[.!?]*\s*$"#

        if text.range(of: sleepPattern, options: .regularExpression) != nil {
            awake = false
            awaitingRequest = false
            failures = 0
            return .sleep
        }

        let wakePattern = #"(?i)\b(?:tars|wake\s+up)\b[\s,.:;!?—-]*"#
        let wakeRange = text.range(of: wakePattern, options: .regularExpression)

        let wasAwake = awake

        if wakeRange != nil {
            awake = true
        }

        guard awake else { return .ignore }

        // A wake/name mention can occur at the end or inside a real question.
        // Strip only a leading address (including common greetings), never the
        // words before an embedded name. Preserve the full question otherwise.
        let leadingWakePattern =
            #"(?i)^\s*(?:(?:ei|oi|olá|ola|hey|hi|hello|ok|okay)[\s,.:;!?—-]+)?(?:tars|wake\s+up)\b[\s,.:;!?—-]*"#
        let leadingWake = text.range(of: leadingWakePattern, options: .regularExpression)
        let request = leadingWake.map { String(text[$0.upperBound...]) } ?? text
        let cleaned = request.trimmingCharacters(in: .whitespacesAndNewlines)

        failures = 0

        if cleaned.isEmpty {
            awaitingRequest = true
            return wasAwake ? .continueListening : .acknowledge
        }

        awaitingRequest = false
        return .request(cleaned)
    }

    // Service/STT failure does not put TARS to sleep.
    mutating func failed() {
        failures = min(6, failures + 1)
    }

    // Explicit reset returns TARS to sleeping state.
    mutating func reset() {
        failures = 0
        awaitingRequest = false
        awake = false
    }
}

/// Trial quotas are opt-in diagnostics. Operational sessions do not expire.
/// Capture length, silence detection, permission and service-error gates are separate.
struct OnlineVoiceTrialBudget {
    let duration: TimeInterval
    let maxUploads: Int
    let isTrial: Bool
    static func configured(_ session: String?) -> Self {
        switch session {
        case "trial": return Self()
        case "trial-conversation": return Self(conversation: true)
        default: return Self(continuous: true)
        }
    }
    init(conversation: Bool = false, continuous: Bool = false) {
        isTrial = !continuous
        // These bounds are enforced only in an explicitly selected trial.
        duration = conversation ? 86400 : 180
        maxUploads = conversation ? 10000 : 6
    }
    private(set) var startedAt: TimeInterval?
    private(set) var uploads = 0
    mutating func begin(now: TimeInterval) { if startedAt == nil { startedAt = now } }
    func available(now: TimeInterval) -> Bool {
        guard let start = startedAt else { return false }
        guard now >= start, start >= 0, now.isFinite, start.isFinite else { return false }
        return !isTrial || (now - start < duration && uploads < maxUploads)
    }
    mutating func reserveUpload(now: TimeInterval) -> Bool {
        guard available(now: now) else { return false }
        // Saturate the diagnostic counter rather than overflowing a long-lived session.
        if uploads < Int.max { uploads += 1 }
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
        if hasSpeech && now - lastVoiceAt >= 2.2 { return .finish }
        if !hasSpeech && elapsed >= 15 { return .discard }
        return .keepListening
    }
}

/// Containment after physical XR acceptance failed with choppy streaming audio.
/// Fetch the complete approved audio before playback. No voice/model substitution.
/// Keep transport hooks for diagnostic tests, but quarantine every live stream path
/// (including visual sessions and early-response flags) until device revalidation.
enum VoicePlaybackPolicy {
    static func shouldStream(configuration: String?, available: Bool, visualSession: Bool) -> Bool {
        false
    }
}
