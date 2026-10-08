import Foundation
@main struct SpokenRequestChecks {
    static func main() {
        precondition(SpokenRequest.clean("TARS, então, por favor, toca Nina Simone") == "toca Nina Simone")
        precondition(SpokenRequest.clean("Então, não apague minha memória") == "não apague minha memória")
        precondition(SpokenRequest.clean("Eu disse: apague minha memória") == "Eu disse: apague minha memória")
        precondition(SpokenRequest.clean("Toca Então") == "Toca Então")
        for text in ["Pesquisa a cotação da PETR4", "Consulta o tempo em Ribeirão Preto agora", "Chegou email novo no Gmail?", "Leia meus e-mails"] {
            precondition(SpokenRequest.isServiceQuery(text))
        }
        for text in ["Abre o Gmail", "Abre Stocks", "Toca Nina Simone", "Pare", "Avance"] {
            precondition(!SpokenRequest.isServiceQuery(text))
        }
        print("PASS: shared speech cleanup, negation preservation and service routing")
    }
}
