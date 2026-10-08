import Foundation
@main struct Checks {
    static func main() async throws {
        precondition(MusicCommand.parse("TARS, toque 54-46 de Toots and the Maytals no YouTube") == .play("54-46 de Toots and the Maytals"))
        precondition(MusicCommand.parse("Toca uma música") == .play(""))
        precondition(MusicCommand.parse("Pause a música") == .pause)
        precondition(MusicCommand.parse("Continue a música") == .resume)
        precondition(MusicCommand.parse("Pare a música") == .stop)
        precondition(MusicCommand.parse("pare") == nil)
        precondition(MusicCommand.parse("Palmeiras joga hoje?") == nil)
        precondition(MusicCommand.parse("abre o Deezer") == nil)
        precondition(MusicCommand.parse("toca Imagine no Deezer") == nil)
        precondition(YouTubeSearch.firstTrack(in: "captcha") == nil)
        let html = try String(contentsOfFile: "Tests/Fixtures/youtube-search.html", encoding: .utf8)
        guard let found = YouTubeSearch.firstTrack(in: html) else { fatalError("real search parser failed") }
        print("Real HTML result:",found.title,found.id)
        if ProcessInfo.processInfo.environment["TARS_TEST_LIVE_SEARCH"] == "1" {
            let live = try await YouTubeSearch.find("Toots 54-46 live")
            print("Live result:",live.title,live.id)
        }
        precondition(MusicCommand.parse("Toca Construção do Chico Buarque.") == .play("Construção do Chico Buarque."))
        precondition(!MusicSpeechPolicy.accepts("Clear and Loud", musicActive: true))
        precondition(MusicSpeechPolicy.accepts("Tars, quando o Palmeiras joga?", musicActive: true))
        precondition(MusicSpeechPolicy.accepts("Toca Construção do Chico Buarque", musicActive: true))
        precondition(MusicSpeechPolicy.accepts("Quando o Palmeiras joga?", musicActive: false))
        precondition(MusicCommand.parse("Toca, toca a construção do Chico Buarque.") == .play("a construção do Chico Buarque."))
        for phrase in ["Pause", "TARS, pause.", "Tars, pausa"] {
            precondition(MusicCommand.parse(phrase, mediaActive: true) == .pause)
        }
        precondition(MusicCommand.parse("Stop", mediaActive: true) == .stop)
        precondition(MusicCommand.parse("Play", mediaActive: true) == .resume)
        precondition(MusicCommand.parse("Stop") == nil)
        precondition(MusicInterruption.phrase(in: "trecho cantado Tars, pause", mediaActive: true) == "TARS, pause a música")
        precondition(MusicInterruption.phrase(in: "never stop the music", mediaActive: true) == nil)
        precondition(MusicInterruption.phrase(in: "Tars pause", mediaActive: false) == nil)
        for phrase in ["Tars, continua com a música.", "Tars, play the music.", "continue com a música", "resume the music", "play it"] {
            precondition(MusicCommand.parse(phrase, mediaActive: true) == .resume)
        }
        precondition(MusicCommand.parse("Tars, pause the music.", mediaActive: true) == .pause)
        precondition(MusicInterruption.phrase(in: "lyrics Tars, pause the music.", mediaActive: true) == "TARS, pause a música")
        precondition(MusicCommand.parse("Toca Nina Simone, Stars.") == .play("Nina Simone, Stars."))
        precondition(MusicCommand.parse("Play Nina Simone Stars") == .play("Nina Simone Stars"))
        precondition(MusicCommand.parse("Não toca essa música") == nil)
        precondition(MusicCommand.parse("Don't play the music") == nil)
        precondition(MusicCommand.parse("Então toca Secretária.") == .play("Secretária."))
        precondition(MusicCommand.parse("Play Secretária.") == .play("Secretária."))
        precondition(MusicCommand.parse("Toca Secretária, Amado Batista.") == .play("Secretária, Amado Batista."))
        for phrase in ["Começa de novo.", "TARS, começa do início", "Start over", "Toca de novo", "Reinicia a faixa, vai.", "Reinicie a faixa", "Restart"] {
            precondition(MusicCommand.parse(phrase, mediaActive: true) == .restart)
        }
        precondition(MusicCommand.parse("Start", mediaActive: true) == .resume)
        precondition(MusicCommand.parse("Start") == nil)
        precondition(MusicCommand.parse("Tá bom, para.", mediaActive: true) == .stop)
        precondition(MusicInterruption.phrase(in: "Tá bom, para.", mediaActive: true) == "TARS, pare a música")
        precondition(MusicCommand.parse("Então não toca Secretária") == nil)
        precondition(MusicCommand.parse("Play Então", mediaActive: true) == .play("Então"))
        print("PASS: music commands, safe routing, real HTML parser")
    }
}
