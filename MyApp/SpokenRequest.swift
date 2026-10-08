import Foundation

/// Shared, conservative preprocessing. Keep negation and named entities intact.
enum SpokenRequest {
    nonisolated static func clean(_ raw: String) -> String {
        var text = raw.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for _ in 0..<4 {
            let previous = text
            text = text.replacingOccurrences(of: #"(?i)^(?:(?:ei|oi|hey)[, :]+)?tars\b[\s,.:;!?—-]*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?i)^(?:ent[aã]o|por favor|por gentileza|please)[\s,:;]+"#, with: "", options: .regularExpression)
            if previous == text { break }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Queries stay in TARS; only an explicit open-app request is a handoff.
    nonisolated static func isServiceQuery(_ raw: String) -> Bool {
        let text = clean(raw).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        if text.range(of: #"^(?:abre|abra|abrir|open|vai no|vai na)\b"#, options: .regularExpression) != nil { return false }
        return text.range(of: #"\b(?:chover|chove|chuva|temperatura|previsao|tempo|clima|cotacao|acoes|acao|stocks|dolar|euro|bitcoin|email|emails|e-mail|e-mails|gmail|yahoo|caixa de entrada)\b"#, options: .regularExpression) != nil
    }
}
