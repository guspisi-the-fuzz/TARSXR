import Foundation

/// Explicit, bounded commands. This parser never extracts memories from model replies.
enum XRMemoryIntent: Equatable {
    enum Attribute: String, Equatable, CaseIterable {
        case birthDate = "nascimento"
        case birthPlace = "local nascimento"
        case deathDate = "falecimento"
        case burialDate = "sepultamento"
    }

    case save(subject: String, statement: String, correction: Bool)
    case forget(String)
    case recall(String, explicit: Bool)
    case recallAttribute(reference: String, attribute: Attribute)
    case help
    case ordinary

    nonisolated private static func commandText(_ raw: String) -> String {
        return SpokenRequest.clean(raw)
    }

    nonisolated private static func captures(_ pattern: String, in input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: input).map { String(input[$0]) } ?? ""
        }
    }

    nonisolated private static func trimEnd(_ text: String) -> String {
        text.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speech recognition often drops question marks. Never offer interrogative text as a fact.
    nonisolated static func isQuestionLike(_ raw: String) -> Bool {
        let text = commandText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("?") { return true }
        return captures(#"(?i)(?:^|[.!?]\s*)(?:que\s+(?:dia|data|horas)|quem|qual|quais|quando|onde|como|por\s+que|porque|o\s+que|who|what|when|where|how|why)\b"#, in: text) != nil
    }

    nonisolated private static func directive(_ raw: String) -> (content: String, correction: Bool)? {
        guard raw.utf8.count <= 4096 else { return nil }
        let text = commandText(raw)
        let verbs = "guarde|guarda|lembre-se|lembre|anote|anota|salve|salva|memorize|memoriza|grave|grava|remember|save|corrija|corrige|corrigir|correct|update"
        let modal = #"^(?:(?:você|voce)\s+)?(?:pode|poderia)\s+(guardar|anotar|salvar|memorizar|gravar|corrigir)\b[\s,.:;]*(.*)$"#
        let want = #"^(?:eu\s+)?quero\s+que\s+(?:(?:você|voce)\s+)?(guarde|guarda|anote|anota|salve|salva|memorize|memoriza|grave|grava|corrija|corrige)\b[\s,.:;]*(.*)$"#
        guard let parts = captures("^(" + verbs + #")\b[\s,.:;]*(.*)$"#, in: text) ?? captures(modal, in: text) ?? captures(want, in: text) else { return nil }
        var content = parts[1]
        // The requested destination is not part of the fact's subject. Consume only
        // a known store destination; never remove arbitrary words or repair ASR text.
        content = content.replacingOccurrences(
            of: #"(?i)^(?:(?:na|em)\s+(?:sua\s+)?mem[oó]ria(?:\s+(?:(?:(?:do|no|desse|deste|nesse|neste)\s+)?(?:aparelho|dispositivo|iphone|xr)|local|persistente))?|in\s+(?:your\s+)?(?:device\s+)?memory)\b[\s,.:;]*"#,
            with: "", options: .regularExpression)
        content = content.replacingOccurrences(of: #"(?i)^(?:de que|que|that)\s+"#, with: "", options: .regularExpression)
        content = content.replacingOccurrences(of: #"(?i)[\s,]+(?:por favor|please)[.!?]*$"#, with: "", options: .regularExpression)
        return (trimEnd(content), ["corrija", "corrige", "corrigir", "correct", "update"].contains(parts[0].lowercased()))
    }

    /// Only an explicit, empty directive authorizes a single subsequent fact.
    /// A false value means save; true means correction; nil means no authorization.
    nonisolated static func pendingDirective(_ raw: String) -> Bool? {
        guard let request = directive(raw), request.content.isEmpty else { return nil }
        return request.correction
    }

    nonisolated private static func nameOwner(_ subject: String) -> String? {
        captures(#"^(?:o\s+)?nome\s+(?:da|do|de)\s+(.+)$"#, in: subject)?.first
            ?? captures(#"^(?:the\s+)?name\s+of\s+(.+)$"#, in: subject)?.first
    }

    /// Subject comparison aliases only. Persisted schema-v1 keys are NOT rewritten.
    nonisolated static func referenceKey(_ subject: String) -> String {
        XRPersistentMemory.key(nameOwner(subject) ?? subject)
    }

    /// Used only after an explicit directive in this or the immediately previous turn.
    nonisolated static func fact(_ raw: String, correction: Bool) -> XRMemoryIntent? {
        guard raw.utf8.count <= 480 else { return nil }
        let text = trimEnd(commandText(raw))
        // Do not reinterpret negation, quotations, reported speech or hypotheses as a fact.
        guard captures(#"^(?:n[aã]o|nunca|do not|don't|eu disse|ele disse|ela disse|voc[eê] disse|talvez|se|if)\b"#, in: text) == nil else { return nil }
        let named = captures(#"^(.{1,80}?)\s+(?:chama-se|chamava-se|se\s+chama|se\s+chamava|chama|is\s+called|is\s+named)\s+(.+)$"#, in: text)
        let simple = captures(#"^(.{1,80}?)\s+(?:é|is)\s+(.+)$"#, in: text)
        guard let parts = named ?? simple else { return nil }
        let subject = nameOwner(parts[0]) ?? parts[0]
        guard XRPersistentMemory.validSubject(subject), !parts[1].isEmpty,
              captures(#"\b(?:n[aã]o|not|never)\b"#, in: subject) == nil,
              text.utf8.count <= 480,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Explicit naming assertions must contain a name, not another command/sentence.
        if named != nil || nameOwner(parts[0]) != nil {
            guard isName(parts[1]) else { return nil }
        }
        return .save(subject: subject, statement: text, correction: correction)
    }

    nonisolated private static func isName(_ text: String) -> Bool {
        guard XRPersistentMemory.validSubject(text),
              captures(#"^([\p{L}][\p{L} .'-]{0,79})$"#, in: text) != nil else { return false }
        let words = XRPersistentMemory.key(text).split(separator: " ").map(String.init)
        let forbidden = Set(["nao", "sei", "desconhecido", "unknown", "forget", "save", "guarde", "grava", "apague", "corrija", "e", "and"])
        return !words.isEmpty && words.count <= 8 && !words.contains(where: forbidden.contains)
    }

    nonisolated private static func relation(_ raw: String) -> String? {
        let key = XRPersistentMemory.key(raw)
        let roles = "mae|pai|irma|irmao|avo|tia|tio|filha|filho|esposa|marido|parceira|parceiro|namorada|namorado|amiga|amigo|gata|gato|cachorra|cachorro|mother|father|sister|brother|wife|husband|partner|daughter|son|cat|dog"
        if captures("^((?:minha|meu|my) (?:" + roles + ")(?: (?:materna|materno|paterna|paterno))?)$", in: key) != nil {
            return key
        }
        // Preserve the other person's qualifier: 'mae da daniela' is not 'minha mae'.
        if captures("^((?:" + roles + #") (?:da|do|de|of) [\p{L}][\p{L} '\-]{0,60})$"#, in: key) != nil { return key }
        return nil
    }

    /// Primary subject and explicit personal names only. Deletion must not retain
    /// the description ('my cat', etc.) merely because it was searchable by relation.
    nonisolated static func identityKeys(subject: String, statement: String) -> Set<String> {
        var keys: Set<String> = [XRPersistentMemory.key(subject), referenceKey(subject)]
        let text = trimEnd(commandText(statement))
        if let named = captures(#"^(.{1,80}?)\s+(?:chama-se|chamava-se|se\s+chama|se\s+chamava|chama|is\s+called|is\s+named)\s+(.+)$"#, in: text),
           referenceKey(named[0]) == referenceKey(subject), isName(named[1]) {
            keys.insert(XRPersistentMemory.key(named[1]))
        }
        if let parts = captures(#"^(.{1,80}?)\s+(?:é|is)\s+(.+)$"#, in: text),
           referenceKey(parts[0]) == referenceKey(subject) {
            if nameOwner(parts[0]) != nil && isName(parts[1]) { keys.insert(XRPersistentMemory.key(parts[1])) }
            if relation(parts[0]) != nil, isName(parts[1]), parts[1].first?.isUppercase == true {
                keys.insert(XRPersistentMemory.key(parts[1]))
            }
        }
        keys.remove("")
        return keys
    }

    /// Read-only aliases from explicit identity clauses, not from mere mentions.
    /// 'Mel lives with Daniela' never makes Daniela a mother/partner.
    nonisolated static func referenceKeys(subject: String, statement: String) -> Set<String> {
        var keys = identityKeys(subject: subject, statement: statement)
        if let split = splitAttributeSubject(subject) {
            keys.insert(XRPersistentMemory.key(split.entity))
        }
        if let parts = captures(#"^(.{1,80}?)\s+(?:é|is)\s+(.+)$"#, in: trimEnd(commandText(statement))),
           referenceKey(parts[0]) == referenceKey(subject), let role = relation(parts[1]) {
            keys.insert(role)
        }
        return keys
    }



    nonisolated static func attributeSubject(entity: String, attribute: Attribute) -> String {
        "\(trimEnd(entity)) \(attribute.rawValue)"
    }

    nonisolated static func splitAttributeSubject(_ subject: String) -> (entity: String, attribute: Attribute)? {
        let normalized = XRPersistentMemory.key(subject)
        for attribute in Attribute.allCases.sorted(by: { $0.rawValue.count > $1.rawValue.count }) {
            let suffix = " " + XRPersistentMemory.key(attribute.rawValue)
            guard normalized.hasSuffix(suffix) else { continue }
            let rawSuffixCount = attribute.rawValue.count + 1
            guard subject.count > rawSuffixCount else { continue }
            let idx = subject.index(subject.endIndex, offsetBy: -rawSuffixCount)
            let entity = String(subject[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            if XRPersistentMemory.validSubject(entity) { return (entity, attribute) }
        }
        return nil
    }

    nonisolated static func attributeValue(statement: String, attribute: Attribute) -> String? {
        let text = trimEnd(commandText(statement))
        let pattern: String
        switch attribute {
        case .birthDate: pattern = #"^.{1,120}?\s+nasceu\s+em\s+(.+)$"#
        case .birthPlace: pattern = #"^.{1,120}?\s+nasceu\s+em\s+(.+)$"#
        case .deathDate: pattern = #"^.{1,120}?\s+(?:faleceu|morreu)\s+em\s+(.+)$"#
        case .burialDate: pattern = #"^.{1,120}?\s+foi\s+sepultad[oa]\s+(?:em|no\s+dia)\s+(.+)$"#
        }
        return captures(pattern, in: text)?.first.map(trimEnd)
    }

    /// Parse several durable attributes for one person without replacing the person's
    /// relationship/identity fact. Each attribute gets its own schema-v1 subject key.
    nonisolated static func entityAttributeFacts(_ raw: String, correction: Bool? = nil) -> [(subject: String, statement: String)]? {
        guard raw.utf8.count <= 4096 else { return nil }
        var text = commandText(raw)
        var effectiveCorrection = correction ?? false
        if let request = directive(text) {
            effectiveCorrection = correction ?? request.correction
            text = request.content
        }
        text = trimEnd(text)
        text = text.replacingOccurrences(of: #"(?i)^eu\s+(?:estou\s+)?afirmando\s+que\s+"#, with: "", options: .regularExpression)
        guard !text.isEmpty else { return nil }

        // User birthday is a device-owner attribute and does not need a person name.
        if let parts = captures(#"^(?:o\s+dia\s+do\s+)?meu\s+anivers[aá]rio\s+(?:é|e|cai\s+em)\s+(.+)$"#, in: text) {
            let value = trimEnd(parts[0])
            guard !value.isEmpty, value.utf8.count <= 120 else { return nil }
            return [("meu aniversário", "Meu aniversário é \(value)")]
        }

        // Combined relation identity + birthday in one natural sentence.
        // Example: "O nome do meu pai é Orlando Pise e o aniversário dele é 6 de setembro de 1940".
        let relationNameBirthdayPatterns = [
            #"^(?:o\s+)?nome\s+d[oa]\s+(.+?)\s+(?:é|e)\s+(.+?)\s+e\s+(?:o\s+)?(?:anivers[aá]rio|nascimento|data\s+de\s+(?:nascimento|anivers[aá]rio))\s+(?:dele|dela|d[oa]\s+.+?)\s+(?:é|e)\s+(.+)$"#,
            #"^(.+?)\s+(?:chama-se|chamava-se|se\s+chama|se\s+chamava)\s+(.+?)\s+e\s+(?:o\s+)?(?:anivers[aá]rio|nascimento|data\s+de\s+(?:nascimento|anivers[aá]rio))\s+(?:dele|dela|d[oa]\s+.+?)\s+(?:é|e)\s+(.+)$"#
        ]
        for pattern in relationNameBirthdayPatterns {
            guard let parts = captures(pattern, in: text) else { continue }
            let reference = trimEnd(parts[0])
            let name = trimEnd(parts[1])
            let value = trimEnd(parts[2])
            guard XRPersistentMemory.validSubject(reference), isName(name), !value.isEmpty, value.utf8.count <= 120 else { return nil }
            return [
                (reference, "\(reference) se chama \(name)"),
                (attributeSubject(entity: reference, attribute: .birthDate), "\(reference) nasceu em \(value)")
            ]
        }

        // Relationship-owned birth date, e.g. "a data de nascimento/aniversário do meu pai é ...".
        if let parts = captures(#"^(?:a\s+)?(?:data\s+de\s+)?(?:nascimento|anivers[aá]rio)\s+(?:d[oa]\s+)(.+?)\s+(?:é|e)\s+(.+?)(?:[.;]?\s*(?:e\s+)?(?:o\s+)?nome\s+(?:dele|dela)\s+(?:é|e)\s+(.+))?$"#, in: text) {
            let reference = trimEnd(parts[0]), value = trimEnd(parts[1])
            guard XRPersistentMemory.validSubject(reference), !value.isEmpty, value.utf8.count <= 120 else { return nil }
            var facts = [(attributeSubject(entity: reference, attribute: .birthDate), "\(reference) nasceu em \(value)")]
            if parts.count > 2, !parts[2].isEmpty, isName(trimEnd(parts[2])) {
                let name = trimEnd(parts[2])
                facts.append((reference, "\(reference) se chama \(name)"))
            }
            return facts
        }

        // Named person's birth place/date, death date and burial date. Dates are kept
        // verbatim so spelling and day/month values never depend on the model.
        let date = #"([0-9]{1,2}\s+de\s+[\p{L}çÇãÃõÕáÁéÉíÍóÓúÚ]+\s+de\s+[0-9]{4})"#
        let birthPattern = #"^(.{1,80}?)\s+nasceu\s+em\s+(.+?)[,;]?\s+(?:no\s+dia|em)\s+"# + date + #"(?:[,;]?\s+(?:e\s+)?(?:faleceu|morreu)\s+em\s+"# + date + #")?(?:[,;]?\s+(?:e\s+)?foi\s+sepultad[oa]\s+(?:no\s+dia|em)\s+"# + date + #")?(?:[,;].*)?$"#
        if let parts = captures(birthPattern, in: text) {
            let entity = trimEnd(parts[0])
            let place = trimEnd(parts[1]).replacingOccurrences(of: #"(?i),?\s+(?:no|na)\s+$"#, with: "", options: .regularExpression)
            let born = trimEnd(parts[2]), died = parts[3].isEmpty ? nil : trimEnd(parts[3]), buried = parts[4].isEmpty ? nil : trimEnd(parts[4])
            guard isName(entity), !place.isEmpty else { return nil }
            var out = [
                (attributeSubject(entity: entity, attribute: .birthPlace), "\(entity) nasceu em \(place)"),
                (attributeSubject(entity: entity, attribute: .birthDate), "\(entity) nasceu em \(born)")
            ]
            if let died { out.append((attributeSubject(entity: entity, attribute: .deathDate), "\(entity) faleceu em \(died)")) }
            if let buried { out.append((attributeSubject(entity: entity, attribute: .burialDate), "\(entity) foi sepultado em \(buried)")) }
            return out
        }

        // Attribute-only assertions for an already known named person.
        let patterns: [(Attribute, String, String)] = [
            (.deathDate, #"^(.{1,80}?)\s+(?:faleceu|morreu)\s+em\s+(.+)$"#, "faleceu em"),
            (.burialDate, #"^(.{1,80}?)\s+foi\s+sepultad[oa]\s+(?:no\s+dia|em)\s+(.+)$"#, "foi sepultado em")
        ]
        for (attribute, pattern, verb) in patterns {
            guard let parts = captures(pattern, in: text) else { continue }
            let entity = trimEnd(parts[0]), value = trimEnd(parts[1])
            guard isName(entity), !value.isEmpty else { return nil }
            return [(attributeSubject(entity: entity, attribute: attribute), "\(entity) \(verb) \(value)")]
        }
        _ = effectiveCorrection // Correction semantics are applied by the runtime/store.
        return nil
    }

    nonisolated static func explicitEntityAttributeFacts(_ raw: String) -> (facts: [(subject: String, statement: String)], correction: Bool)? {
        guard let request = directive(raw), !request.content.isEmpty,
              let facts = entityAttributeFacts(request.content, correction: request.correction) else { return nil }
        return (facts, request.correction)
    }

    nonisolated static func suggestedAttributeFacts(_ raw: String) -> [(subject: String, statement: String)]? {
        guard directive(raw) == nil, !isQuestionLike(raw) else { return nil }
        return entityAttributeFacts(raw, correction: false)
    }

    nonisolated static func recallAttributeQuery(_ raw: String) -> (reference: String, attribute: Attribute)? {
        let text = commandText(raw).replacingOccurrences(of: #"(?i)^(?:e|and)[\s,]+"#, with: "", options: .regularExpression)
        let patterns: [(Attribute, String)] = [
            (.birthDate, #"^qual\s+(?:é|e)\s+(?:a\s+)?data\s+de\s+(?:nascimento|anivers[aá]rio)\s+d[oa]\s+(.+?)[.!?]*$"#),
            (.birthDate, #"^(?:quando|em\s+que\s+dia)\s+(.+?)\s+nasceu[.!?]*$"#),
            (.birthDate, #"^quando\s+(.+?)\s+nasceu[.!?]*$"#),
            (.birthPlace, #"^onde\s+(.+?)\s+nasceu[.!?]*$"#),
            (.deathDate, #"^quando\s+(.+?)\s+(?:faleceu|morreu)[.!?]*$"#),
            (.burialDate, #"^quando\s+(.+?)\s+foi\s+sepultad[oa][.!?]*$"#)
        ]
        for (attribute, pattern) in patterns {
            if let parts = captures(pattern, in: text) {
                let reference = trimEnd(parts[0])
                if XRPersistentMemory.validSubject(reference) { return (reference, attribute) }
            }
        }
        return nil
    }

    /// Parse two sibling names into two independent person-owned facts.
    /// The explicit form writes immediately; the suggested form only asks for confirmation.
    nonisolated private static func relationshipFactsFromContent(_ content: String) -> [(subject: String, statement: String)]? {
        let clean = trimEnd(content)
        let patterns = [
            #"^(?:o\s+nome\s+do\s+)?meu\s+irm[aã]o\s+(?:é|e|chama-se|se\s+chama)\s+(.+?)\s+e\s+(?:do\s+)?outro\s+irm[aã]o\s+meu\s+(?:é|e|chama-se|se\s+chama)\s+(.+)$"#,
            #"^(?:o\s+nome\s+dos\s+)?meus\s+irm[aã]os\s+(?:s[aã]o|é|e|se\s+chamam)\s+(.+?)\s+e\s+(.+)$"#,
            #"^(?:os\s+nomes\s+dos\s+)?meus\s+irm[aã]os\s+(?:s[aã]o|é|e|se\s+chamam)\s+(.+?)\s+e\s+(.+)$"#
        ]
        for pattern in patterns {
            guard let names = captures(pattern, in: clean) else { continue }
            let first = trimEnd(names[0]), second = trimEnd(names[1])
            guard isName(first), isName(second), XRPersistentMemory.key(first) != XRPersistentMemory.key(second) else { return nil }
            return [(first, "\(first) é meu irmão"), (second, "\(second) é meu irmão")]
        }
        return nil
    }

    nonisolated static func compoundRelationshipFacts(_ raw: String) -> [(subject: String, statement: String)]? {
        guard let request = directive(raw), !request.correction else { return nil }
        return relationshipFactsFromContent(request.content)
    }

    nonisolated static func suggestedCompoundRelationshipFacts(_ raw: String) -> [(subject: String, statement: String)]? {
        guard directive(raw) == nil, !isQuestionLike(raw) else { return nil }
        return relationshipFactsFromContent(commandText(raw))
    }

    nonisolated private static func spelledName(_ raw: String) -> String? {
        let letters = raw.uppercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(String.init)
        guard letters.count >= 2, letters.count <= 20 else { return nil }
        let lower = letters.joined().lowercased()
        guard let first = lower.first else { return nil }
        return String(first).uppercased() + String(lower.dropFirst())
    }

    /// Explicit proper-name correction. Never guesses the old entity.
    nonisolated static func renameCorrection(_ raw: String) -> (old: String, new: String)? {
        let text = commandText(raw)
        let patterns = [
            #"^(?:corrija|corrige|corrigir)\s+(.+?)\s+(?:para|por)\s+(.+?)[.!?]*$"#,
            #"^(.+?)[,;]?\s+(?:corrija|corrige)[.!,:;\s]+(.+?)[.!?]*$"#,
            #"^corrigindo\s+(?:de\s+)?(.+?)\s+para\s+(.+?)[.!?]*$"#,
            #"^(?:n[aã]o[, ]+)*(?:n[aã]o\s+)?(?:é|e)\s+(.+?)[,;]\s*(?:é|e)\s+(.+?)(?:[.;]\s*([A-Za-z](?:[-\s.]+[A-Za-z]){1,}))?[.!?]*$"#
        ]
        for pattern in patterns {
            guard let values = captures(pattern, in: text) else { continue }
            let old = trimEnd(values[0]).trimmingCharacters(in: CharacterSet(charactersIn: ",;:. "))
            let spelled = values.count > 2 && !values[2].isEmpty ? spelledName(values[2]) : nil
            let candidateNew = trimEnd(values[1]).trimmingCharacters(in: CharacterSet(charactersIn: ",;:. "))
            let new = spelled ?? candidateNew
            guard isName(old), isName(new), XRPersistentMemory.key(old) != XRPersistentMemory.key(new) else { return nil }
            return (old, new)
        }
        return nil
    }

    /// Relationship query aliases are normalized for lookup only. Stored facts stay untouched.
    nonisolated static func canonicalRelationQuery(_ raw: String) -> String? {
        let key = XRPersistentMemory.key(raw)
        let mapping: [String: String] = [
            "meu irmao": "meu irmao", "meus irmaos": "meu irmao",
            "minha irma": "minha irma", "minhas irmas": "minha irma",
            "minha mae": "minha mae", "meu pai": "meu pai",
            "minha esposa": "minha esposa", "meu marido": "meu marido",
            "minha parceira": "minha parceira", "meu parceiro": "meu parceiro"
        ]
        return mapping[key]
    }

    /// Extract the exact saved display name when a fact expresses a named relationship.
    nonisolated static func displayName(subject: String, statement: String) -> String? {
        let relationSubject = canonicalRelationQuery(subject) != nil || relation(subject) != nil || nameOwner(subject) != nil
        if !relationSubject, isName(subject) { return subject }
        let text = trimEnd(commandText(statement))
        if let named = captures(#"^(.{1,80}?)\s+(?:chama-se|chamava-se|se\s+chama|se\s+chamava|chama|is\s+called|is\s+named)\s+(.+)$"#, in: text),
           isName(named[1]) { return trimEnd(named[1]) }
        if let simple = captures(#"^(.{1,80}?)\s+(?:é|is)\s+(.+)$"#, in: text) {
            if (canonicalRelationQuery(simple[0]) != nil || relation(simple[0]) != nil), isName(simple[1]) { return trimEnd(simple[1]) }
            if isName(simple[0]), canonicalRelationQuery(simple[1]) != nil || relation(simple[1]) != nil { return trimEnd(simple[0]) }
        }
        return nil
    }

    /// Convert first-person user-owned facts into second-person speech without changing names.
    nonisolated static func naturalizedStatement(_ statement: String) -> String {
        var out = trimEnd(statement)
        let replacements: [(String, String)] = [
            (#"(?i)\bminha\b"#, "sua"), (#"(?i)\bmeu\b"#, "seu"),
            (#"(?i)\bminhas\b"#, "suas"), (#"(?i)\bmeus\b"#, "seus"),
            (#"(?i)\bcomigo\b"#, "com você")
        ]
        for (pattern, value) in replacements {
            out = out.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
        }
        if let first = out.first, first.isLowercase {
            out.replaceSubrange(out.startIndex...out.startIndex, with: String(first).uppercased())
        }
        return out + "."
    }

    nonisolated static func parse(_ raw: String) -> XRMemoryIntent {
        guard raw.utf8.count <= 4096 else { return .help }
        let text = commandText(raw)
        if let request = directive(text) {
            return fact(request.content, correction: request.correction) ?? .help
        }
        if let parts = captures(#"^(?:esqueça|esqueca|esquecer|apague|forget)\s+(?:(?:tudo sobre|everything about|sobre|about)\s+)?(.+?)[.!?]*$"#, in: text) {
            let subject = nameOwner(parts[0]) ?? parts[0]
            let key = XRPersistentMemory.key(subject)
            guard XRPersistentMemory.validSubject(subject), !["tudo", "tudo sobre", "all", "everything"].contains(key) else { return .help }
            return .forget(subject)
        }
        // ASR often omits punctuation in a direct birthday question.
        if captures(#"^(?:que\s+(?:dia|data)\s+(?:(?:é|e)\s+)?(?:o\s+)?|quando\s+(?:(?:é|e)\s+)?(?:o\s+)?)meu\s+anivers[aá]rio[.!?]*$"#, in: text) != nil {
            return .recall("meu aniversário", explicit: true)
        }
        // Remove a discourse 'e/and' only from read-only questions, never to authorize writes.
        let question = text.replacingOccurrences(of: #"(?i)^(?:e|and)[\s,]+"#, with: "", options: .regularExpression)
        let nameQuestion = #"^(?:qual\s+(?:é\s+|e\s+)?o\s+nome\s+(?:da|do|de)|como\s+(?:se\s+)?chama|como\s+é\s+o\s+nome\s+(?:da|do|de)|(?:(?:você|voce)\s+)?(?:se\s+)?lembra\s+(?:d[oa]\s+|o\s+)?nome\s+(?:da|do|de)|what\s+is\s+the\s+name\s+of)\s+(.+?)[.!?]*$"#
        if let parts = captures(nameQuestion, in: question) {
            let subject = nameOwner(parts[0]) ?? parts[0]
            guard XRPersistentMemory.validSubject(subject) else { return .help }
            return .recall(subject, explicit: true)
        }
        if let parts = captures(#"^(?:o que (?:você |voce )?(?:lembra|sabe|tem salvo) sobre|what do you (?:remember|know) about)\s+(.+?)[.!?]*$"#, in: question) {
            return .recall(parts[0], explicit: true)
        }
        if let parts = captures(#"^(?:(?:você|voce)\s+)?(?:se\s+)?lembra\s+(?:de\s+)?quem\s+(?:é|e)\s+(.+?)[.!?]*$"#, in: question) {
            return .recall(parts[0], explicit: true)
        }
        if let parts = captures(#"^(?:quem (?:é|e)|who is)\s+(.+?)[.!?]*$"#, in: question) {
            return .recall(parts[0], explicit: relation(parts[0]) != nil || nameOwner(parts[0]) != nil)
        }
        if captures(#"^(?:quando\s+(?:é|e)\s+|qual(?:\s+é|\s+e)?\s+(?:(?:o\s+dia|a\s+data)\s+do\s+)?)meu\s+anivers[aá]rio[.!?]*$"#, in: question) != nil {
            return .recall("meu aniversário", explicit: true)
        }
        if let attribute = recallAttributeQuery(question) {
            return .recallAttribute(reference: attribute.reference, attribute: attribute.attribute)
        }
        let siblingQuestion = #"^(?:(?:eu\s+tenho\s+(?:dois|duas|2)\s+irm[aã]os?[.!?]?[\s]*)?quais\s+(?:s[aã]o\s+)?os\s+nomes\s+deles|quais\s+(?:s[aã]o\s+)?os\s+nomes\s+dos\s+meus\s+irm[aã]os|qual\s+(?:(?:é|e)\s+)?(?:o\s+)?nome\s+dos\s+meus\s+irm[aã]os|quem\s+s[aã]o\s+(?:os\s+)?meus\s+irm[aã]os|como\s+se\s+chamam\s+(?:os\s+)?meus\s+irm[aã]os)[.!?]*$"#
        if captures(siblingQuestion, in: question) != nil { return .recall("meu irmão", explicit: true) }
        return .ordinary
    }


    /// A conservative candidate for a personal fact mentioned in ordinary speech.
    /// It never writes by itself; the runtime must ask for confirmation first.
    nonisolated static func suggestedFact(_ raw: String) -> XRMemoryIntent? {
        let text = commandText(raw)
        guard !isQuestionLike(text),
              directive(text) == nil, renameCorrection(text) == nil, compoundRelationshipFacts(text) == nil,
              let candidate = fact(text, correction: false) else { return nil }
        switch candidate {
        case .save(let subject, let statement, _):
            let key = XRPersistentMemory.key(subject)
            // Keep suggestions to personal/household facts. Arbitrary world statements
            // continue to the model and are never offered as durable memory.
            let personal = key.hasPrefix("minha ") || key.hasPrefix("meu ") || key.hasPrefix("minhas ") || key.hasPrefix("meus ")
                || statement.range(of: #"(?i)\b(?:minha|meu|minhas|meus|comigo|moro|moramos|my|with me)\b"#, options: .regularExpression) != nil
            return personal ? candidate : nil
        default:
            return nil
        }
    }

    nonisolated static func confirmsSuggestion(_ raw: String) -> Bool {
        captures(#"^(?:sim|yes|sim[, ]+eu\s+quero|eu\s+quero|quero\s+sim|pode|pode\s+sim|sim[, ]+pode|pode\s+(?:guardar|gravar|salvar|memorizar)|(?:eu\s+)?quero\s+que\s+(?:(?:você|voce)\s+)?(?:guarde|guarda|grave|grava|salve|salva|memorize|memoriza)|claro|isso|isso\s+mesmo|guarde|guarda|salve|salva|grave|grava|memorize|lembre|ok|okay|(?:eu\s+)?(?:quero\s+que\s+)?(?:você\s+|voce\s+)?(?:grave|grava|guarde|salve)\s+(?:essa|esta|essas|estas)\s+informa[cç](?:[aã]o|[oõ]es)(?:\s+(?:(?:no|neste|nesse)\s+xr|(?:na|nesta|nessa)\s+mem[oó]ria|(?:no|neste|nesse)\s+aparelho))?(?:\s+corretamente)?)[.!?]*$"#, in: commandText(raw)) != nil
    }

    nonisolated static func rejectsSuggestion(_ raw: String) -> Bool {
        captures(#"^(?:n[aã]o|nao|no|n[aã]o precisa|nao precisa|deixa|deixa pra l[aá]|deixa para l[aá]|melhor n[aã]o|cancela|cancel)[.!?]*$"#, in: commandText(raw)) != nil
    }

    nonisolated static func cancelled(_ raw: String) -> Bool {
        captures(#"^(?:cancela|cancele|cancelar|cancel|deixa pra l[aá]|deixa para l[aá]|n[aã]o (?:grave|grava|guarde|salve|salva)|never mind|do not save)[.!?]*$"#, in: commandText(raw)) != nil
    }

    nonisolated static func english(_ text: String) -> Bool {
        guard text.utf8.count <= 4096 else { return false }
        return commandText(text).range(of: #"(?i)^(?:remember|save|correct|update|forget|who|what|how|why|tell|explain)\b"#,
                                      options: .regularExpression) != nil
    }
}
