import Foundation

/// Regression contract: wake persists until explicit sleep/reset, not a 30-second window.
@main struct Checks {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        var p = VoiceActivationPolicy()
        for ambient in ["olá", "stars", "tarsiano", "como está o tempo", "Hi Carlos", "Hi Thaís", "Karen", ""] {
            check(p.consume(ambient) == .ignore, "Ambient speech cannot wake TARS: \(ambient)")
        }
        check(p.consume("Ei, TARS!") == .acknowledge, "First wake acknowledged")
        check(p.awake && p.awaitingRequest, "Wake authorizes the next request")
        check(p.consume("Como está o tempo?") == .request("Como está o tempo?"), "Request after wake")
        check(p.consume("outra conversa") == .request("outra conversa"), "Follow-up persists without repeated wake")
        check(p.consume("TARS") == .continueListening, "Repeated wake must not repeat the greeting")
        check(p.consume("") == .ignore && p.awake && p.awaitingRequest, "Silence preserves wake and pending request")
        p.failed()
        check(p.awake && p.awaitingRequest, "STT failure does not put TARS to sleep")
        check(p.consume("tente de novo") == .request("tente de novo"), "Conversation continues after failure")
        for _ in 0..<20 { p.failed() }
        check(p.retrySeconds == 30, "Backoff remains capped")
        p.reset()
        check(!p.awake && !p.awaitingRequest && p.retrySeconds == 0.6, "Explicit reset sleeps and clears failures")
        check(p.consume("depois do reset") == .ignore, "A new wake is required after reset")
        check(p.consume("tArS: diga olá") == .request("diga olá"), "Wake and request together")
        check(p.consume("TARS, tell me a joke") == .request("tell me a joke"), "English request")
        for sleep in ["sleep", "go to sleep", "TARS, go to sleep!", "dorme", "pode dormir", "vai dormir", "fica quieto", "fique quieto"] {
            _ = p.consume("TARS")
            check(p.consume(sleep) == .sleep && !p.awake, "Explicit sleep: \(sleep)")
            check(p.consume("fala ambiente") == .ignore, "Ambient speech after sleep")
        }
        check(p.consume("wake up") == .acknowledge, "English wake")
        check(p.consume("tell me about sleep") == .request("tell me about sleep"), "A mention of sleep is not a sleep command")
        var sleeping = VoiceActivationPolicy()
        sleeping.replyFinished(now: 100)
        check(!sleeping.awake && sleeping.consume("hello") == .ignore, "A reply does not wake a sleeping policy")
        var sustained = VoiceActivationPolicy()
        _ = sustained.consume("TARS, olá", now: 100)
        for turn in 0..<1000 {
            let now = 100 + Double(turn) * 100
            sustained.replyFinished(now: now)
            let text = turn % 2 == 0 ? "continua em português" : "continue in English"
            precondition(sustained.consume(text, now: now + 60) == .request(text), "Persistent turn \(turn)")
        }
        check(sustained.awake, "1000 follow-ups beyond the old timeout stay awake")
        sustained.failed()
        check(sustained.consume("depois da falha", now: 200000) == .request("depois da falha"), "Failure and long pause preserve wake")

        // Wake/name mentions must never erase the actual question.
        let preserved = [
            "Me conta uma piada, TARS",
            "Quanto é dois mais dois, TARS?",
            "Explique o nome TARS em duas palavras",
            "Eu disse TARS, mas minha pergunta é outra",
            "Você pode explicar o comando wake up?",
            "Eu não quero que você se mova, TARS",
            "Não avance, TARS, me conte uma piada",
            "Por que chamaram o robô de TARS no filme?"
        ]
        for phrase in preserved {
            for initiallyAwake in [false, true] {
                var routed = VoiceActivationPolicy()
                if initiallyAwake { _ = routed.consume("TARS") }
                check(routed.consume(phrase) == .request(phrase), "Preserve complete phrase: \(phrase)")
                check(routed.awake, "Name still authorizes wake")
            }
        }
        for greeting in ["Ei, TARS!", "Oi TARS", "Hey, TARS!", "Hello, wake up", "Olá, TARS"] {
            var routed = VoiceActivationPolicy()
            check(routed.consume(greeting) == .acknowledge, "Greeting plus wake only: \(greeting)")
            check(routed.consume(greeting) == .continueListening, "Do not repeat greeting: \(greeting)")
        }
        var mixed = VoiceActivationPolicy()
        check(mixed.consume("TARS, explique TARS em português") == .request("explique TARS em português"), "Remove only leading address")
        check(mixed.consume("Ei, TARS, tell me a joke") == .request("tell me a joke"), "Greeting plus request")
        check(mixed.consume("wake up, explain the phrase wake up") == .request("explain the phrase wake up"), "Preserve second wake mention")
        check(mixed.consume("estou perguntando como ir dormir, TARS") == .request("estou perguntando como ir dormir, TARS"), "Mention of sleeping is not a command")
        check(mixed.consume("pode dormir") == .sleep, "Explicit sleep still works after name-preserving requests")
        check(mixed.consume("me conta outra piada") == .ignore, "Sleep still blocks ambient requests")

        // Physical regression containment: no flags or vision may bypass batch mode.
        let configurations: [String?] = [nil, "1", "0", ""]
        for configuration in configurations {
            for available in [false, true] {
                for visual in [false, true] {
                    let actual = VoicePlaybackPolicy.shouldStream(configuration: configuration, available: available, visualSession: visual)
                    let expected = false
                    check(actual == expected, "Streaming selection matrix")
                }
            }
        }
        check(!VoicePlaybackPolicy.shouldStream(configuration: nil, available: true, visualSession: false), "Default buffers the complete approved voice")
        check(!VoicePlaybackPolicy.shouldStream(configuration: "1", available: true, visualSession: false), "Old streaming flag cannot reenable regression")
        check(!VoicePlaybackPolicy.shouldStream(configuration: "1", available: true, visualSession: true), "Vision cannot bypass containment")
        check(!VoicePlaybackPolicy.shouldStream(configuration: "0", available: true, visualSession: false), "Explicit batch opt-out respected")
        check(!VoicePlaybackPolicy.shouldStream(configuration: nil, available: false, visualSession: false), "Absent stream never selected")

        // Production selection must not stop after 6 uploads, 3 minutes or 24 hours.
        for session: String? in [nil, "conversation", "operational", ""] {
            var operation = OnlineVoiceTrialBudget.configured(session)
            check(!operation.isTrial, "Normal launch is not a trial")
            check(!operation.available(now: 100), "Operation must be started")
            operation.begin(now: 100)
            for upload in 0..<20000 {
                precondition(operation.reserveUpload(now: 100 + Double(upload) * 10))
            }
            check(operation.uploads == 20000, "Continuous counter survives the old upload limit")
            check(operation.available(now: 1_000_000), "Continuous session survives the old day limit")
            operation.begin(now: 1_000_100)
            check(operation.uploads == 20000 && operation.startedAt == 100, "Foreground does not reset counters")
            check(!operation.available(now: 99), "Operation rejects backwards time")
            check(!operation.available(now: .nan) && !operation.available(now: .infinity), "Operation rejects nonfinite time")
        }
        var invalidOperation = OnlineVoiceTrialBudget.configured(nil)
        invalidOperation.begin(now: -1)
        check(!invalidOperation.available(now: 10), "Negative initial uptime rejected")
        let explicitTrial = OnlineVoiceTrialBudget.configured("trial")
        check(explicitTrial.isTrial && explicitTrial.maxUploads == 6, "Short diagnostic is explicit")
        let extendedTrial = OnlineVoiceTrialBudget.configured("trial-conversation")
        check(extendedTrial.isTrial && extendedTrial.maxUploads == 10000, "Long diagnostic is explicit")

        var budget = OnlineVoiceTrialBudget()
        check(!budget.available(now: 100), "Budget must be started")
        budget.begin(now: 100)
        check(!budget.available(now: 99), "Budget rejects reversed time")
        for _ in 0..<6 { precondition(budget.reserveUpload(now: 110)) }
        check(!budget.reserveUpload(now: 110), "Short trial still caps uploads")
        budget.begin(now: 120)
        check(!budget.available(now: 120), "Starting again does not refill")
        var expiry = OnlineVoiceTrialBudget(); expiry.begin(now: 100)
        check(expiry.available(now: 279) && !expiry.available(now: 280), "Short trial time bound preserved")
        var extended = OnlineVoiceTrialBudget(conversation: true); extended.begin(now: 100)
        check(extended.duration == 86400 && extended.maxUploads == 10000, "Current bench budget unchanged")
        for _ in 0..<10000 { precondition(extended.reserveUpload(now: 500)) }
        check(!extended.reserveUpload(now: 501), "Extended budget is still bounded")
        extended.begin(now: 600)
        check(!extended.available(now: 600), "Extended budget cannot be refilled by begin")
        var timed = OnlineVoiceTrialBudget(conversation: true); timed.begin(now: 100)
        check(timed.available(now: 86499.9) && !timed.available(now: 86500), "Extended time boundary")
        check(!timed.available(now: .nan) && !timed.available(now: .infinity), "Nonfinite budget clocks rejected")
        let silence = VoiceCaptureWindow(now: 100)
        check(silence.decision(now: 114.99) == .keepListening && silence.decision(now: 115) == .discard, "Silent capture timeout")
        var phrase = VoiceCaptureWindow(now: 100); phrase.observeVoice(now: 102)
        check(phrase.decision(now: 104.19) == .keepListening && phrase.decision(now: 104.21) == .finish, "Current 2.2-second pause preserved")
        var resumed = VoiceCaptureWindow(now: 100); resumed.observeVoice(now: 102)
        resumed.observeVoice(now: 103.3)
        check(resumed.decision(now: 105.49) == .keepListening && resumed.decision(now: 105.51) == .finish, "Resumed speech resets pause timing")
        var continuous = VoiceCaptureWindow(now: 100)
        for second in 100..<120 {
            continuous.observeVoice(now: Double(second))
            precondition(continuous.decision(now: Double(second)) == .keepListening)
        }
        check(continuous.decision(now: 120) == .finish, "20-second capture limit preserved")
        check(silence.decision(now: 103, hasTranscript: true) == .finish, "Transcript can finish capture")
        for time in [99.0, Double.infinity, Double.nan] {
            check(silence.decision(now: time) == .discard, "Invalid capture clock rejected")
        }
        var invalid = VoiceCaptureWindow(now: 100); invalid.observeVoice(now: 99)
        check(invalid.decision(now: 101) == .discard, "Invalid observation rejected")
        check(VoiceCaptureWindow(now: .nan).decision(now: 101) == .discard, "Invalid start time rejected")
        check(VoiceCaptureWindow(now: 200).decision(now: 203) == .keepListening, "Capture state does not leak between requests")
        print("PASS: \(checks) voice checks, plus 1000 follow-ups and budget/capture boundary loops")
    }
}
