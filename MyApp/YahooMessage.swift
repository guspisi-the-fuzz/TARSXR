import Foundation

enum YahooMessage {
    static func fields(_ raw: String) -> (headers: [String: String], body: String) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let pieces = text.components(separatedBy: "\n\n")
        let header = pieces.first ?? ""
        let unfolded = header.replacingOccurrences(of: #"\n[ \t]+"#, with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (headers, pieces.dropFirst().joined(separator: "\n\n"))
    }
    static func decoded(_ text: String, encoding: String, charset: String) -> String? {
        let data: Data
        if encoding.lowercased() == "base64" {
            guard let value = Data(base64Encoded: text.filter { !$0.isWhitespace }) else { return nil }; data = value
        } else if encoding.lowercased() == "quoted-printable" {
            let bytes = Array(text.replacingOccurrences(of: "=\n", with: "").utf8); var output = [UInt8](); var i = 0
            while i < bytes.count {
                if bytes[i] == 61 {
                    guard i + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[i+1...i+2], as: UTF8.self), radix: 16) else { return nil }
                    output.append(byte); i += 3
                } else { output.append(bytes[i]); i += 1 }
            }; data = Data(output)
        } else { data = Data(text.utf8) }
        switch charset.lowercased() {
        case "iso-8859-1", "latin1": return String(data: data, encoding: .isoLatin1)
        case "windows-1252": return String(data: data, encoding: .windowsCP1252)
        default: return String(data: data, encoding: .utf8)
        }
    }
    static func header(_ text: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let ns = text as NSString
            let encoding = ns.substring(with: match.range(at: 2)).lowercased() == "b" ? "base64" : "quoted-printable"
            var value = ns.substring(with: match.range(at: 3))
            if encoding == "quoted-printable" { value = value.replacingOccurrences(of: "_", with: " ") }
            if let decoded = decoded(value, encoding: encoding, charset: ns.substring(with: match.range(at: 1))), let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decoded) }
        }
        return MailText.clean(result, limit: 160)
    }
    static func parameter(_ name: String, _ value: String) -> String? {
        let pattern = "(?i)(?:^|;)\\s*" + name + #"\s*=\s*(?:"([^"]+)"|([^;\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for index in [1, 2] { if let range = Range(match.range(at: index), in: value) { return String(value[range]) } }
        return nil
    }
    static func body(_ raw: String, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        let (headers, text) = fields(raw)
        let type = headers["content-type"] ?? "text/plain"
        guard !(headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") else { return nil }
        if type.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", type) {
            for part in text.components(separatedBy: "--" + boundary).dropFirst().prefix(20) {
                if part.hasPrefix("--") { break }
                if let value = body(part.trimmingCharacters(in: .newlines), depth: depth + 1) { return value }
            }
            return nil
        }
        guard type.lowercased().hasPrefix("text/plain") else { return nil }
        return decoded(text, encoding: headers["content-transfer-encoding"] ?? "8bit", charset: parameter("charset", type) ?? "utf-8").map { MailText.clean($0, limit: 1600) }
    }
    static func summary(_ raw: String, includeBody: Bool) -> String {
        let (fields, _) = fields(raw)
        let subject = header(fields["subject"] ?? "Sem assunto")
        let sender = header(fields["from"] ?? "Remetente não informado")
        var result = "De \(sender). Assunto: \(subject)."
        if includeBody { result += " Trecho da mensagem: " + (body(raw) ?? "Não há texto simples disponível para leitura.") }
        return result
    }
}
