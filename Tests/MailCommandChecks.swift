import Foundation
@main struct MailCommandChecks {
    static func main() {
        precondition(MailCommand.parse("TARS, chegou email novo?") == .unread)
        precondition(MailCommand.parse("Verifique meu Yahoo") == .unread)
        precondition(MailCommand.parse("Leia o último email") == .readLatest)
        precondition(MailCommand.parse("Conectar Yahoo") == .connect)
        precondition(MailCommand.parse("Desconectar Yahoo") == .disconnect)
        precondition(MailCommand.parse("Chegou email no Yahoo?") == .unread)
        precondition(MailCommand.parse("Abre o Gmail") == nil)
        precondition(MailCommand.parse("Não leia meus emails") == nil)
        precondition(MailCommand.parse("Leia o email do banco") == .clarify)
        precondition(MailCommand.parse("Verifique meu Gmail") == .gmailUnavailable)
        let payload: [String: Any] = ["mimeType":"multipart/mixed", "parts":[["mimeType":"text/plain", "body":["data":Data("Olá, mensagem de teste.".utf8).base64EncodedString()]]]]
        precondition(MailText.plainBody(payload) == "Olá, mensagem de teste.")
        precondition(MailText.plainBody(["mimeType":"application/octet-stream"]) == nil)
        print("PASS: mail intents, negations, message selection and plain-text MIME decoding")
    }
}
