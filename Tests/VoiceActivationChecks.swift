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
        print("Voice activation checks PASS")
    }
}
