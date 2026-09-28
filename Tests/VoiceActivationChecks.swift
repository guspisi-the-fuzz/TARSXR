import Foundation
@main struct Checks {
    static func main() {
        var p = VoiceActivationPolicy()
        for ambient in ["olá", "stars", "tarsiano", "como está o tempo", ""] {
            assert(p.consume(ambient) == .ignore)
        }
        assert(p.consume("Ei, TARS!") == .acknowledge)
        assert(p.consume("Como está o tempo?") == .request("Como está o tempo?"))
        assert(p.consume("outra conversa") == .ignore)
        assert(p.consume("TARS, olá") == .request("olá"))
        assert(p.consume("TARS") == .acknowledge)
        assert(p.consume("") == .ignore)
        assert(p.consume("fala ambiente") == .ignore)
        assert(p.consume("TARS") == .acknowledge)
        p.failed()
        assert(!p.awaitingRequest)
        assert(p.consume("não repetir pedido antigo") == .ignore)
        for _ in 0..<20 { p.failed() }
        assert(p.retrySeconds == 30)
        p.reset()
        assert(p.retrySeconds == 0.6 && !p.awaitingRequest)
        assert(p.consume("tArS: diga olá") == .request("diga olá"))
        assert(p.consume("Hey TARS!") == .acknowledge)
        assert(p.consume("What time is it?") == .request("What time is it?"))
        assert(p.consume("TARS, qual é a capital do Brasil?") == .request("qual é a capital do Brasil?"))
        assert(p.consume("TARS, tell me a joke") == .request("tell me a joke"))
        assert(p.consume("background conversation") == .ignore)
        var budget = OnlineVoiceTrialBudget()
        assert(!budget.available(now: 100))
        budget.begin(now: 100)
        assert(!budget.available(now: 99))
        for _ in 0..<6 { assert(budget.reserveUpload(now: 110)) }
        assert(!budget.reserveUpload(now: 110))
        budget.begin(now: 120)
        assert(!budget.available(now: 120))
        var expiry = OnlineVoiceTrialBudget()
        expiry.begin(now: 100)
        assert(expiry.available(now: 279))
        assert(!expiry.reserveUpload(now: 280))
        print("Voice activation PT/EN and bounded online trial checks PASS")
    }
}
