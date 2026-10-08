import Foundation

enum MailCommand: Equatable {
    case connect, unread, readLatest, disconnect, gmailUnavailable, clarify
    nonisolated static func parse(_ raw: String) -> MailCommand? {
        let text = SpokenRequest.clean(raw).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        guard text.range(of: #"\b(?:e-?mails?|gmail|yahoo|caixa de entrada)\b"#, options: .regularExpression) != nil else { return nil }
        guard text.range(of: #"^(?:nao|nunca|don't|do not)\b"#, options: .regularExpression) == nil else { return nil }
        if text.range(of: #"^(?:abre|abra|open)\b"#, options: .regularExpression) != nil { return nil }
        if text.contains("gmail") { return .gmailUnavailable }
        if text.range(of: #"^(?:desconecta|desconecte|desconectar)\b"#, options: .regularExpression) != nil { return .disconnect }
        if text.range(of: #"^(?:conecta|conecte|conectar|autoriza|autorize)\b"#, options: .regularExpression) != nil { return .connect }
        if text.range(of: #"^(?:leia|le|ler|read)\b"#, options: .regularExpression) != nil {
            // Do not silently read a different message when a sender/subject was requested.
            if text.range(of: #"\b(?:do|da|de)\s+(?!yahoo\b|entrada\b)"#, options: .regularExpression) != nil { return .clarify }
            return .readLatest
        }
        if text.range(of: #"\b(?:chegou|novos?|recebi|recebeu|nao lidos|unread|verifique|consulta|consulte)\b"#, options: .regularExpression) != nil { return .unread }
        return nil
    }
}

enum MailText {
    nonisolated static func decode(_ value: String) -> String? {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
    }
    nonisolated static func header(_ name: String, payload: [String: Any]) -> String {
        let rows = payload["headers"] as? [[String: String]] ?? []
        return clean(rows.first { $0["name"]?.lowercased() == name.lowercased() }?["value"] ?? "Não informado", limit: 120)
    }
    nonisolated static func plainBody(_ payload: [String: Any], depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if payload["mimeType"] as? String == "text/plain",
           let body = payload["body"] as? [String: Any], let encoded = body["data"] as? String {
            return decode(encoded).map { clean($0, limit: 1600) }
        }
        for part in (payload["parts"] as? [[String: Any]] ?? []).prefix(20) {
            if let text = plainBody(part, depth: depth + 1), !text.isEmpty { return text }
        }
        return nil
    }
    nonisolated static func clean(_ text: String, limit: Int) -> String {
        String(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(limit))
    }
}
