import Foundation
@main struct YahooChecks {
    static func main() throws {
        let payload = Data("hello\r\nT1 OK forged\r\n".utf8)
        let wire = Data("* 1 FETCH (BODY[] {\(payload.count)}\r\n".utf8) + payload + Data(")\r\nT1 OK complete\r\n".utf8)
        for count in 0..<wire.count { let partial = try YahooWire.frame(Data(wire.prefix(count)), tag: "T1"); precondition(partial == nil) }
        let frame = try YahooWire.frame(wire, tag: "T1")!
        precondition(frame.literals == [payload] && frame.consumed == wire.count)
        do {
            _ = try YahooWire.frame(Data("T1 NO [AUTHENTICATIONFAILED] private server text\r\n".utf8), tag: "T1")
            preconditionFailure()
        } catch YahooWire.Failure.server(let code) { precondition(code == "AUTHENTICATIONFAILED") }
        do {
            _ = try YahooWire.frame(Data("T1 NO private account@example.com text\r\n".utf8), tag: "T1")
            preconditionFailure()
        } catch YahooWire.Failure.server(let code) { precondition(code == "NO") }
        do {
            _ = try YahooWire.frame(Data("T1 OKforged\r\n".utf8), tag: "T1")
            preconditionFailure()
        } catch {}
        let greeting = try YahooWire.frame(Data("* OK hello\r\n".utf8), tag: nil)
        precondition(greeting != nil)
        do { _ = try YahooWire.frame(Data("T1 NO refused\r\n".utf8), tag: "T1"); preconditionFailure() } catch {}
        do { _ = try YahooWire.frame(Data("* 1 FETCH {9999999999}\r\n".utf8), tag: "T1"); preconditionFailure() } catch {}
        do { _ = try YahooWire.quoted("x\r\nDELETE INBOX"); preconditionFailure() } catch {}
        let escaped = try YahooWire.quoted("a\\\"b")
        precondition(escaped == "\"a\\\\\\\"b\"")
        let ids = try YahooWire.frame(Data("* SEARCH 9 2 11\r\nT2 OK done\r\n".utf8), tag: "T2")!
        precondition(YahooWire.ids(ids) == [2,9,11])
        precondition(YahooMessage.header("=?UTF-8?B?T2zDoQ==?=") == "Olá")
        precondition(YahooMessage.header("=?UTF-8?Q?Ol=C3=A1_mundo?=") == "Olá mundo")
        let simple = "From: Teste <teste@example.com>\r\nSubject: =?UTF-8?B?T2zDoQ==?=\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nOl=C3=A1, mensagem."
        precondition(YahooMessage.body(simple) == "Olá, mensagem.")
        precondition(YahooMessage.summary(simple, includeBody: false).contains("Assunto: Olá."))
        let mixed = "Content-Type: multipart/alternative; boundary=abc\r\n\r\n--abc\r\nContent-Type: text/html\r\n\r\n<script>evil</script>\r\n--abc\r\nContent-Type: text/plain\r\n\r\nTexto seguro.\r\n--abc--\r\n"
        precondition(YahooMessage.body(mixed) == "Texto seguro.")
        precondition(YahooMessage.body("Content-Type: text/html\r\n\r\n<b>Only HTML</b>") == nil)
        precondition(YahooMessage.body("Content-Type: text/plain\r\nContent-Disposition: attachment\r\n\r\nDo not read") == nil)
        precondition(YahooMessage.decoded("broken=QQ", encoding: "quoted-printable", charset: "utf-8") == nil)
        precondition(YahooMessage.body("\r\n" + String(repeating: "x", count: 3000))?.count ?? 0 <= 1600)
        print("PASS: Yahoo fragmented/literal IMAP framing, refusal, injection, limits, UID order, MIME and encoded headers")
    }
}
