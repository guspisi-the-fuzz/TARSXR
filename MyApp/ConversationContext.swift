import Foundation

/// Process-local conversational evidence, never a persistent fact store or an action queue.
struct ConversationContext {
    enum Source: String { case conversation, memory, camera, mail, music, external }
    struct Turn {
        let question: String
        let answer: String
        let source: Source
        let time: Double
        let capturedAt: Double?
    }
    private(set) var turns: [Turn] = []
    private var identity: String?
    private(set) var generation = UUID()
    let lifetime: Double = 300

    mutating func synchronize(owner: String, revision: String) {
        let next = owner + "/" + revision
        if let identity, identity != next { clear() }
        identity = next
    }
    mutating func clear() { turns = []; generation = UUID() }
    mutating func append(question: String, answer: String, source: Source, now: Double, capturedAt: Double? = nil) {
        guard now.isFinite, now >= 0, !question.isEmpty, !answer.isEmpty,
              question.count <= 2000, answer.count <= 2000,
              capturedAt.map({ $0.isFinite && $0 >= 0 && $0 <= now }) ?? true else { return }
        let retention = lifetime
        turns.removeAll { now < $0.time || now - $0.time > retention }
        // A description may cross the shared button and voice paths. Record it once.
        if let last = turns.last, last.question == question, last.answer == answer,
           last.source == source, now - last.time < 5 { return }
        turns.append(.init(question: question, answer: answer, source: source, time: now, capturedAt: capturedAt))
        turns = Array(turns.suffix(8)); generation = UUID()
    }
    func payload(now: Double) -> [[String: Any]] {
        guard now.isFinite, now >= 0 else { return [] }
        return turns.filter { now >= $0.time && now - $0.time <= lifetime }.map { turn in
            var value: [String: Any] = ["question": turn.question, "answer": turn.answer,
                "source": turn.source.rawValue, "age_seconds": now - turn.time,
                "authority": "dialogue_only_no_actions"]
            if turn.source == .camera {
                value["historical_observation"] = true
                value["current_environment_verified"] = false
                if let captured = turn.capturedAt { value["capture_age_seconds"] = now - captured }
            }
            return value
        }
    }
}

/// Pure policies shared by the device and deterministic offline checks.
enum ConversationPolicy {
    static func isPersonal(_ raw: String) -> Bool {
        let text = SpokenRequest.clean(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        return text.range(of: #"\b(meu|minha|meus|minhas|comigo|memoria|lembra|lembre|salv[ao]|guard[ae]|esqueca|esquece|corrija|my|mine|remember|forget)\b"#, options: .regularExpression) != nil
    }
    static func usesReference(_ raw: String) -> Bool {
        raw.range(of: #"(?i)\b(ela|ele|elas|eles|isso|dela|dele|she|he|it|they|al[eé]m de mim)\b"#, options: .regularExpression) != nil
    }
    /// Short opening, then at most two larger pieces. Exact text is preserved.
    /// Uses complete MP3s, not the PCM transport quarantined after XR failure.
    static func speechParts(_ text: String) -> [String] {
        guard text.count > 240 else { return [text] }
        let chars = Array(text)
        let candidates = (60..<min(chars.count, 240)).filter {
            ".!?;\n".contains(chars[$0]) && ($0 + 1 == chars.count || chars[$0 + 1].isWhitespace)
        }
        guard let split = candidates.first else { return [text] }
        let first = String(chars[...split])
        let rest = String(chars[(split + 1)...])
        return [first, rest]
    }
}

/// Only explicit requests for current visual evidence enter the paid image path.
/// Historical follow-ups remain ordinary dialogue; no implicit camera activation.
enum VisualQuestionPolicy {
    static func explicitCurrent(_ raw: String) -> Bool {
        let t = SpokenRequest.clean(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        if t.range(of: #"^(nao|nunca|do not|dont|don't)\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"\b(viu|via|estava|estavam|antes|anterior|descreveu|saw|previous)\b"#, options: .regularExpression) != nil { return false }
        return t.range(of: #"\b(enxergando|vendo)\b|\bvoce ve\b|\bdescrev[ae]\b.*\b(camera|imagem|objetos|tela|ve)\b|\b(lei[ae]|ler)\b.*\b(tela|codigo|texto|imagem)\b|\b(procura|procure)\b.*\b(na imagem|na camera)\b"#, options: .regularExpression) != nil
    }
    static func needsTextDetail(_ raw: String) -> Bool {
        let t = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
        return t.range(of: #"\b(lei[ae]|ler|texto|codigo|escrito|read|text|code)\b"#, options: .regularExpression) != nil
    }
}

/// Barge-in only controls the conversation, never the robot. Exact phrases avoid
/// treating ordinary ambient speech or a partial transcript as a tool command.
enum VoiceInterruptionPolicy {
    private static func normalized(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func command(in raw: String) -> String? {
        let text = normalized(raw)
        let pattern = #"\b"# + SpokenRequest.wakeAliasPattern + #"\s+(escuta|me escuta|pare de falar|para de falar|listen|stop speaking)$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: #"^"# + SpokenRequest.wakeAliasPattern + #"\s+"#, with: "tars ", options: .regularExpression)
    }
    static func matches(_ raw: String) -> Bool { command(in: raw) != nil }
    static func echoes(_ command: String, spoken: String) -> Bool { normalized(spoken).contains(command) }
}
