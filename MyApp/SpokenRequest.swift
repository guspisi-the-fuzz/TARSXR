import Foundation

/// Shared, conservative preprocessing. Keep negation and named entities intact.
enum SpokenRequest {
    // Conservative ASR aliases for the robot name. Only used as an address/wake word.
    // Do not add generic words here.
    nonisolated static let wakeAliasPattern = #"(?:tars|t[áa]rs|tais|taís|tarso|tarz|taz|t\s*a\s*r\s*s)"#

    nonisolated static func clean(_ raw: String) -> String {
        var text = raw.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        for _ in 0..<4 {
            let previous = text
            let leadingWake = #"(?i)^\s*(?:(?:ei|oi|olá|ola|hey|hi|hello|ok|okay)[\s,.:;!?—-]+)?(?:\b"# + wakeAliasPattern + #"\b)[\s,.:;!?—-]*"#
            text = text.replacingOccurrences(of: leadingWake, with: "", options: .regularExpression)
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
