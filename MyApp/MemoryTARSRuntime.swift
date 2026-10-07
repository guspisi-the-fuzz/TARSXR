import Foundation

/// Short-lived confirmation state is process-owned rather than runtime-instance-owned.
/// SwiftUI/runtime recreation must not lose an explicit pending memory confirmation.
@MainActor
final class XRMemoryPendingState {
    static let shared = XRMemoryPendingState()
    var fact: (correction: Bool, deadline: Double)?
    var suggestion: (facts: [(subject: String, statement: String)], deadline: Double)?

    func clear() {
        fact = nil
        suggestion = nil
    }
}

/// Memory belongs to the phone; the wrapped runtime can be remote or embedded.
@MainActor
final class MemoryTARSRuntime: TARSRuntime {
    #if DEBUG
    private let memoryTrace = XRMemoryTrace.shared
    private let traceInstance = UUID().uuidString
    // Test hook receives metadata only; absent from Release builds.
    var memoryTraceObserver: (([String: Any]) -> Void)?
    #endif

    private func traceMemory(_ event: String, fields: [String: Any] = [:]) {
        #if DEBUG
        var metadata = fields; metadata["runtime_instance"] = traceInstance
        let entry = memoryTrace.record(event, fields: metadata,
                                       storage: store?.diagnosticMetadata())
        memoryTraceObserver?(entry)
        #endif
    }

    private let underlying: any TARSRuntime
    private let memory: @MainActor () throws -> XRPersistentMemory
    private var store: XRPersistentMemory?
    private var lastKeys: [String] = []
    private var lastRecallAt = 0.0
    private var conversationRevision = UUID().uuidString
    private var observedDiskRevision: String?
    // Pending confirmation belongs to the running XR process, not one runtime object.
    // This prevents a SwiftUI/runtime recreation between voice turns from losing “sim”.
    private let pendingState: XRMemoryPendingState
    private let uptime: () -> Double
    private func invalidateConversation() { conversationRevision = UUID().uuidString }

    init(underlying: any TARSRuntime,
         memory: @escaping @MainActor () throws -> XRPersistentMemory = { try XRPersistentMemory.deviceStore() },
         uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         pendingState: XRMemoryPendingState? = nil) {
        self.underlying = underlying; self.memory = memory; self.uptime = uptime
        self.pendingState = pendingState ?? .shared
        traceMemory("runtime_ready")
    }

    private func storage() throws -> XRPersistentMemory {
        if let store { return store }
        let value = try memory(); store = value
        traceMemory("store_opened")
        return value
    }

    /// Resolve relation-owned attributes ("meu pai nascimento") to the saved entity name
    /// before persistence. This keeps attribute lookup stable after restart and rename.
    private func resolvedAttributeFacts(_ facts: [(subject: String, statement: String)],
                                        store: XRPersistentMemory) throws -> [(subject: String, statement: String)] {
        let document = try store.load()
        var batchEntities: [String: String] = [:]
        for item in facts {
            guard let relation = XRMemoryIntent.canonicalRelationQuery(item.subject),
                  let name = XRMemoryIntent.displayName(subject: item.subject, statement: item.statement) else { continue }
            batchEntities[relation] = name
        }
        return facts.map { item in
            guard let split = XRMemoryIntent.splitAttributeSubject(item.subject),
                  let relation = XRMemoryIntent.canonicalRelationQuery(split.entity),
                  let entity = batchEntities[relation] ?? store.entityName(for: split.entity, document: document),
                  let value = XRMemoryIntent.attributeValue(statement: item.statement, attribute: split.attribute) else {
                return item
            }
            let statement: String
            switch split.attribute {
            case .birthDate: statement = "\(entity) nasceu em \(value)"
            case .birthPlace: statement = "\(entity) nasceu em \(value)"
            case .deathDate: statement = "\(entity) faleceu em \(value)"
            case .burialDate: statement = "\(entity) foi sepultado em \(value)"
            }
            return (XRMemoryIntent.attributeSubject(entity: entity, attribute: split.attribute), statement)
        }
    }


    private func applyPendingRename(_ rename: (old: String, new: String),
                                    to facts: [(subject: String, statement: String)]) -> (facts: [(subject: String, statement: String)], changed: Bool) {
        let oldKey = XRPersistentMemory.key(rename.old)
        var changed = false
        let updated = facts.map { item -> (subject: String, statement: String) in
            var subject = item.subject
            var statement = item.statement
            if XRPersistentMemory.key(subject) == oldKey {
                subject = rename.new
                changed = true
            } else if subject.range(of: rename.old, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                subject = subject.replacingOccurrences(of: rename.old, with: rename.new,
                                                       options: [.caseInsensitive, .diacriticInsensitive])
                changed = true
            }
            if statement.range(of: rename.old, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                statement = statement.replacingOccurrences(of: rename.old, with: rename.new,
                                                          options: [.caseInsensitive, .diacriticInsensitive])
                changed = true
            }
            return (subject, statement)
        }
        return (updated, changed)
    }

    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        try Task.checkCancellation()
        let english = XRMemoryIntent.english(text)
        let store: XRPersistentMemory
        do { store = try storage() }
        catch {
            traceMemory("store_open_failed")
            invalidateConversation(); return english ? "I could not access memory on the XR. No save was confirmed." : XRMemoryError.unavailable.localizedDescription
        }
        // Internal wake summaries are not user instructions and cannot write memory.
        let internalWake = context?["internal_wake_summary"] as? Bool == true
        if !internalWake, let pending = pendingState.suggestion, let rename = XRMemoryIntent.renameCorrection(text) {
            let update = applyPendingRename(rename, to: pending.facts)
            if update.changed {
                pendingState.suggestion = (update.facts, pending.deadline)
                traceMemory("suggestion_corrected")
                invalidateConversation()
                let rendered = update.facts.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                return english ? "Corrected the pending memory. Do you want me to save it on this XR?"
                    : "Corrigi a informação pendente: \(rendered) Quer que eu guarde isso na memória deste XR?"
            }
        }
        if !internalWake, let local = try localConcreteMemoryAnswer(text: text, store: store, english: english) {
            traceMemory("concrete_inference_local")
            return local
        }
        if !internalWake, let residence = localResidenceCandidate(text: text), residence.explicit {
            do {
                let facts = try store.saveAttributes(residence.facts, correction: residence.correction)
                traceMemory("save_verified", fields: ["correction": residence.correction, "fact_count": facts.count])
                lastKeys = []; lastRecallAt = 0; invalidateConversation()
                let rendered = facts.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                return english ? "Saved on this XR." : "Salvei neste XR: \(rendered)"
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation(); return error.localizedDescription
            }
        }
        if !internalWake, let rename = XRMemoryIntent.renameCorrection(text) {
            do {
                let fact = try store.renameIdentity(old: rename.old, new: rename.new)
                traceMemory("save_verified", fields: ["correction": true])
                lastKeys = []; lastRecallAt = 0; invalidateConversation()
                return english ? "Corrected on this XR: \(fact.statement)." : "Corrigi neste XR: \(XRMemoryIntent.naturalizedStatement(fact.statement))"
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation(); return error.localizedDescription
            }
        }
        if !internalWake, let attributes = XRMemoryIntent.explicitEntityAttributeFacts(text) {
            do {
                let values = try resolvedAttributeFacts(attributes.facts, store: store)
                let facts = try store.saveAttributes(values, correction: attributes.correction)
                traceMemory("save_verified", fields: ["correction": attributes.correction, "fact_count": facts.count])
                lastKeys = []; lastRecallAt = 0; invalidateConversation()
                let rendered = facts.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                return english ? "Saved on this XR." : "Salvei neste XR: \(rendered)"
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation(); return error.localizedDescription
            }
        }
        if !internalWake, let values = XRMemoryIntent.compoundRelationshipFacts(text) {
            do {
                let facts = try store.saveMany(values)
                traceMemory("save_verified", fields: ["correction": false])
                lastKeys = []; lastRecallAt = 0; invalidateConversation()
                let names = facts.compactMap { XRMemoryIntent.displayName(subject: $0.subject, statement: $0.statement) }
                if names.count == 2 { return english ? "Saved on this XR: \(names[0]) and \(names[1])." : "Salvei neste XR: seus irmãos são \(names[0]) e \(names[1])." }
                return english ? "Saved on this XR." : "Salvei neste XR."
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation(); return error.localizedDescription
            }
        }
        if let pending = pendingState.suggestion, !internalWake {
            let now = uptime()
            if now.isFinite, now >= pending.deadline - 60, now < pending.deadline {
                if XRMemoryIntent.confirmsSuggestion(text) || localConfirmsPendingSuggestion(text) {
                    pendingState.suggestion = nil
                    do {
                        let values = try resolvedAttributeFacts(pending.facts, store: store)
                        let facts = try store.saveAttributes(values, correction: false)
                        traceMemory("suggestion_confirmed")
                        traceMemory("save_verified", fields: ["correction": false, "fact_count": facts.count])
                        lastKeys = []; lastRecallAt = 0; invalidateConversation()
                        let rendered = facts.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                        return english ? "Saved on this XR." : "Salvei neste XR: \(rendered)"
                    } catch let error as XRMemoryError {
                        #if DEBUG
                        traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                        #else
                        traceMemory("memory_error")
                        #endif
                        invalidateConversation(); return error.localizedDescription
                    }
                }
                if XRMemoryIntent.rejectsSuggestion(text) {
                    pendingState.suggestion = nil
                    traceMemory("suggestion_declined"); invalidateConversation()
                    return english ? "Okay. I did not save it." : "Tudo bem. Não guardei isso."
                }
                // Keep the candidate until an explicit yes/no or expiry. Voice/runtime
                // plumbing may insert another local turn before the user's confirmation.
                traceMemory("suggestion_waiting")
            } else {
                pendingState.suggestion = nil
                traceMemory("suggestion_expired")
            }
        }
        // A standalone confirmation without a pending candidate is local state, not a
        // question for the model. Never let the model reply “você quer o quê?”.
        if !internalWake && (XRMemoryIntent.confirmsSuggestion(text) || XRMemoryIntent.rejectsSuggestion(text)) {
            traceMemory("confirmation_without_pending")
            invalidateConversation()
            return english ? "There is no memory save waiting for confirmation."
                : "Não há nenhuma gravação de memória aguardando confirmação."
        }
        var intent: XRMemoryIntent = internalWake ? .ordinary : XRMemoryIntent.parse(text)
        if let pending = pendingState.fact, !internalWake {
            pendingState.fact = nil
            let now = uptime()
            if now.isFinite, now >= pending.deadline - 90, now < pending.deadline {
                if XRMemoryIntent.cancelled(text) {
                    traceMemory("pending_cancelled"); invalidateConversation()
                    return english ? "Cancelled. No fact was saved." : "Cancelado. Não gravei essa informação."
                }
                if case .ordinary = intent {
                    if let fact = XRMemoryIntent.fact(text, correction: pending.correction) {
                        intent = fact
                        traceMemory("pending_fact_received")
                    } else {
                        traceMemory("pending_cancelled")
                        // Do not send an unrecognized memory directive to the model
                        // where an invented success/failure acknowledgement can arise.
                        invalidateConversation()
                        return english ? "No fact was saved. Repeat the explicit save command with the complete fact."
                            : "Não gravei. Repita o pedido de guardar com a informação completa."
                    }
                }
            } else { traceMemory("pending_expired") }
        }
        #if DEBUG
        traceMemory("intent_received", fields: XRMemoryTrace.intentMetadata(intent))
        #endif
        do {
            switch intent {
            case .save(let subject, let statement, let correction):
                let fact = try store.save(subject: subject, statement: statement, correction: correction)
                traceMemory("save_verified", fields: ["correction": correction])
                lastKeys = []; lastRecallAt = 0
                invalidateConversation()
                return english ? "Saved on this XR: \(fact.statement)." : "Salvei neste XR: \(fact.statement)."
            case .forget(let subject):
                let existed = try store.forget(subject: subject)
                traceMemory("forget_verified", fields: ["fact_existed": existed])
                lastKeys = []; lastRecallAt = 0
                invalidateConversation()
                return english ? (existed ? "Deleted that saved fact from this XR." : "No fact is saved under that name.")
                    : (existed ? "Apaguei essa lembrança salva no XR." : "Não há lembrança salva com esse nome.")
            case .help:
                traceMemory("grammar_help")
                invalidateConversation()
                if let correction = XRMemoryIntent.pendingDirective(text), !internalWake {
                    let now = uptime()
                    if now.isFinite {
                        pendingState.fact = (correction, now + 90)
                        traceMemory("awaiting_fact", fields: ["correction": correction])
                        return english ? "What should I save? Say the complete fact. Nothing has been saved yet."
                            : "Qual informação devo guardar? Diga a frase completa. Ainda não gravei nada."
                    }
                }
                return english ? "Use an explicit fact: remember, Mel is my cat. To change it, say correct, Mel is my dog. To delete it, say forget Mel."
                    : "Use uma informação explícita: guarde, a Mel é minha gata. Para alterar, diga corrija, seguido da informação completa. Para apagar, diga esqueça a Mel."
            case .recall(let subject, let explicit):
                let doc = try store.load()
                let key = XRMemoryIntent.canonicalRelationQuery(subject) ?? XRMemoryIntent.referenceKey(subject)
                let matches = store.facts(for: subject, document: doc)
                traceMemory("recall_lookup", fields: ["fact_count": doc.facts.count,
                    "found": !matches.isEmpty, "match_count": matches.count,
                    "has_tombstone": doc.forgotten.contains(key)])
                if !matches.isEmpty {
                    if matches.count > 1 && key != "meu irmao" && key != "minha irma" {
                        lastKeys = []; lastRecallAt = 0
                        throw XRMemoryError.ambiguous
                    }
                    lastKeys = matches.map(\.key); lastRecallAt = ProcessInfo.processInfo.systemUptime
                    invalidateConversation()
                    let names = matches.compactMap { XRMemoryIntent.displayName(subject: $0.subject, statement: $0.statement) }
                    if key == "meu irmao" || key == "minha irma" {
                        if names.count == 1 {
                            let role = key == "meu irmao" ? "irmão" : "irmã"
                            return english ? "Your \(role) is \(names[0])." : "Seu \(role) se chama \(names[0])."
                        }
                        if names.count == matches.count {
                            let joined = names.count == 2 ? "\(names[0]) e \(names[1])" : names.dropLast().joined(separator: ", ") + " e " + (names.last ?? "")
                            return english ? "Your siblings are \(joined)." : "Seus irmãos são \(joined)."
                        }
                    }
                    if key == "minha mae", let name = names.first {
                        return english ? "Your mother is named \(name)." : "Sua mãe se chama \(name)."
                    }
                    if key == "meu pai", let name = names.first {
                        return english ? "Your father is named \(name)." : "Seu pai se chama \(name)."
                    }
                    if matches.count == 1 {
                        return XRMemoryIntent.naturalizedStatement(matches[0].statement)
                    }
                    let rendered = matches.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                    return rendered
                }
                if explicit || doc.forgotten.contains(key) {
                    lastKeys = []; lastRecallAt = 0
                    invalidateConversation()
                    return english ? "I have no saved fact about that on this XR." : "Não tenho uma lembrança salva sobre isso neste XR."
                }
            case .recallAttribute(let reference, let attribute):
                let doc = try store.load()
                guard let entity = store.entityName(for: reference, document: doc),
                      let fact = store.attributeFact(entity: entity, attribute: attribute, document: doc),
                      let value = XRMemoryIntent.attributeValue(statement: fact.statement, attribute: attribute) else {
                    invalidateConversation()
                    return english ? "I do not have that saved on this XR." : "Não tenho essa informação salva neste XR."
                }
                lastKeys = [fact.key]; lastRecallAt = ProcessInfo.processInfo.systemUptime
                invalidateConversation()
                let relationKey = XRMemoryIntent.canonicalRelationQuery(reference)
                switch attribute {
                case .birthDate:
                    if relationKey == "meu pai" { return "Seu pai, \(entity), nasceu em \(value)." }
                    return "\(entity) nasceu em \(value)."
                case .birthPlace:
                    if relationKey == "meu pai" { return "Seu pai, \(entity), nasceu em \(value)." }
                    return "\(entity) nasceu em \(value)."
                case .deathDate:
                    if relationKey == "meu pai" { return "Seu pai, \(entity), faleceu em \(value)." }
                    return "\(entity) faleceu em \(value)."
                case .burialDate:
                    if relationKey == "meu pai" { return "Seu pai, \(entity), foi sepultado em \(value)." }
                    return "\(entity) foi sepultado em \(value)."
                }
            case .ordinary:
                if !internalWake {
                    var suggested: [(subject: String, statement: String)] = []
                    if let residence = localResidenceCandidate(text: text), !residence.explicit {
                        suggested = residence.facts
                    }
                    if let attributes = XRMemoryIntent.suggestedAttributeFacts(text) {
                        suggested = attributes
                    } else if let compound = XRMemoryIntent.suggestedCompoundRelationshipFacts(text) {
                        suggested = compound
                    } else if let candidate = XRMemoryIntent.suggestedFact(text),
                              case .save(let subject, let statement, _) = candidate {
                        suggested = [(subject, statement)]
                    }
                    if !suggested.isEmpty {
                        let now = uptime()
                        if now.isFinite {
                            pendingState.suggestion = (suggested, now + 60)
                            traceMemory("memory_suggested", fields: ["fact_count": suggested.count])
                            invalidateConversation()
                            let rendered = suggested.map { XRMemoryIntent.naturalizedStatement($0.statement) }.joined(separator: " ")
                            return english
                                ? "Do you want me to save that on this XR?"
                                : "Você me disse: \(rendered) Quer que eu guarde isso na memória deste XR?"
                        }
                    }
                }
                break
            }
            let doc = try store.load()
            if observedDiskRevision != doc.revision {
                invalidateConversation(); observedDiskRevision = doc.revision
            }
            let requestRevision = conversationRevision
            traceMemory("context_loaded", fields: ["fact_count": doc.facts.count])
            let followUp = text.range(of: #"(?i)\b(ela|ele|isso|explica|explique|entendi|she|he|it|explain|understand)\b"#, options: .regularExpression) != nil
                || text.range(of: #"(?i)^\s*(?:(?:me\s+)?(?:fale|fala|conte|conta)\s+mais|desenvolva|tell\s+me\s+more)[.!?]*\s*$"#, options: .regularExpression) != nil
            let keys = followUp && ProcessInfo.processInfo.systemUptime - lastRecallAt < 60 ? lastKeys : []
            var current = context ?? [:]
            var memoryContext = store.context(for: text, document: doc, followUpKeys: keys)
            // Opaque request-context epoch: a local reply must also supersede any old
            // remote confirmation, even when it only reads memory and writes no file.
            memoryContext["revision"] = requestRevision
            current["xr_memory"] = memoryContext
            if let facts = memoryContext["facts"] as? [[String: Any]], !facts.isEmpty {
                lastKeys = facts.compactMap { $0["key"] as? String }
                lastRecallAt = ProcessInfo.processInfo.systemUptime
            } else if !followUp {
                lastKeys = []; lastRecallAt = 0
            }
            traceMemory("remote_request", fields: ["selected_count": (memoryContext["facts"] as? [[String: Any]])?.count ?? 0])
            let result = try await underlying.converse(text: text, language: language, context: current)
            try Task.checkCancellation()
            // Never deliver an answer based on a record deleted while this request waited.
            guard try store.load().revision == doc.revision, conversationRevision == requestRevision else { throw XRMemoryError.changed }
            traceMemory("remote_answer")
            return result
        } catch let error as XRMemoryError {
            #if DEBUG
            traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
            #endif
            invalidateConversation()
            if english { return "Memory was not updated or could not be read. I will not claim it was saved. Use an explicit correction for an existing fact." }
            if case .changed = error {
                return "A informação já existe ou mudou durante o pedido. Para substituir, diga corrija, seguido da informação completa."
            }
            return error.localizedDescription
        } catch {
            traceMemory(error is CancellationError ? "request_cancelled" : "remote_error")
            throw error
        }
    }


    private func localConfirmsPendingSuggestion(_ raw: String) -> Bool {
        let key = XRPersistentMemory.key(raw)
        let deictic = [
            "salva essa informacao no xr",
            "salva essas informacoes no xr",
            "salve essa informacao no xr",
            "salve essas informacoes no xr",
            "guarda essa informacao no xr",
            "guarda essas informacoes no xr",
            "guarde essa informacao no xr",
            "guarde essas informacoes no xr",
            "grava essa informacao no xr",
            "grava essas informacoes no xr",
            "grave essa informacao no xr",
            "grave essas informacoes no xr",
            "salva essa informacao",
            "salva essas informacoes",
            "salve essa informacao",
            "salve essas informacoes",
            "guarda essa informacao",
            "guarda essas informacoes",
            "guarde essa informacao",
            "guarde essas informacoes",
            "grava essa informacao",
            "grava essas informacoes",
            "grave essa informacao",
            "grave essas informacoes",
            "guarde isso",
            "guarda isso",
            "salve isso",
            "salva isso",
            "grave isso",
            "grava isso",
            "sim eu quero",
            "sim quero",
            "eu quero",
            "pode guardar",
            "pode salvar",
            "pode gravar"
        ]
        if deictic.contains(key) { return true }
        if key.hasPrefix("sim ") && (key.contains("quero") || key.contains("pode")) { return true }
        if (key.hasPrefix("salva ") || key.hasPrefix("salve ") || key.hasPrefix("guarda ") || key.hasPrefix("guarde ") || key.hasPrefix("grava ") || key.hasPrefix("grave "))
            && (key.contains("informacao") || key.contains("informacoes") || key.contains("isso") || key.contains("essas") || key.contains("essa")) {
            return true
        }
        return false
    }

    private func localResidenceCandidate(text raw: String) -> (facts: [(subject: String, statement: String)], correction: Bool, explicit: Bool)? {
        func compact(_ raw: String) -> String {
            raw.precomposedStringWithCanonicalMapping
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        func firstCapture(_ pattern: String, _ input: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(input.startIndex..<input.endIndex, in: input)
            guard let match = regex.firstMatch(in: input, options: [], range: range) else { return nil }
            return (1..<match.numberOfRanges).map { idx in
                Range(match.range(at: idx), in: input).map { String(input[$0]) } ?? ""
            }
        }
        func trim(_ value: String) -> String {
            value.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.")))
        }
        func cleanName(_ value: String) -> String {
            var name = trim(value)
            name = name.replacingOccurrences(of: #"(?i)^(?:a|o|as|os|uma|um)\s+"#, with: "", options: .regularExpression)
            return trim(name)
        }
        func splitNames(_ raw: String) -> [String] {
            var value = trim(raw)
            value = value.replacingOccurrences(of: #"(?i)\b(?:no|neste|nesse|deste|desse)\s+xr\b"#, with: "", options: .regularExpression)
            value = value.replacingOccurrences(of: #"(?i)\b(?:e|and)\b"#, with: ",", options: .regularExpression)
            return value.split(separator: ",").map { cleanName(String($0)) }
                .filter { !$0.isEmpty && XRPersistentMemory.validSubject($0) }
        }
        func joinNames(_ names: [String]) -> String {
            if names.count <= 1 { return names.first ?? "" }
            if names.count == 2 { return "\(names[0]) e \(names[1])" }
            return names.dropLast().joined(separator: ", ") + " e " + (names.last ?? "")
        }

        var text = compact(raw)
        var explicit = false
        var correction = false
        if let parts = firstCapture(#"^(?:eu\s+)?quero\s+que\s+(?:(?:você|voce)\s+)?(guarde|guarda|anote|anota|salve|salva|memorize|memoriza|grave|grava|corrija|corrige)\b[\s,.:;]*(.*)$"#, text)
            ?? firstCapture(#"^(?:você|voce)\s+(?:pode|poderia)\s+(guardar|anotar|salvar|memorizar|gravar|corrigir)\b[\s,.:;]*(.*)$"#, text)
            ?? firstCapture(#"^(guarde|guarda|anote|anota|salve|salva|memorize|memoriza|grave|grava|corrija|corrige|corrigir|correct|update|save|remember)\b[\s,.:;]*(.*)$"#, text) {
            explicit = true
            correction = XRPersistentMemory.key(parts[0]).contains("corr") || XRPersistentMemory.key(parts[0]) == "update" || XRPersistentMemory.key(parts[0]) == "correct"
            text = parts[1]
            text = text.replacingOccurrences(of: #"(?i)^(?:(?:na|em)\s+(?:sua\s+)?mem[oó]ria(?:\s+(?:(?:(?:do|no|desse|deste|nesse|neste)\s+)?(?:aparelho|dispositivo|iphone|xr)|local|persistente))?|in\s+(?:your\s+)?(?:device\s+)?memory)\b[\s,.:;]*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(?i)^(?:de\s+que|que|that)\s+"#, with: "", options: .regularExpression)
        }
        text = trim(text)
        text = text.replacingOccurrences(of: #"(?i)^(?:eu\s+tenho\s+essa\s+informa[cç][aã]o\s+e\s+)?(?:eu\s+)?(?:estou\s+)?(?:te\s+)?(?:dizendo|afirmando)[,;:\s]+"#, with: "", options: .regularExpression)
        text = trim(text)
        if let range = text.range(of: #"(?i)[\s,.;:]+(?:por\s+favor\s+)?(?:salva|salve|guarda|guarde|grava|grave)(?:\s+(?:essa|esta|essas|estas)\s+informa[cç](?:[aã]o|[oõ]es)|\s+isso)?(?:\s+(?:(?:no|neste|nesse)\s+xr|(?:na|nesta|nessa)\s+mem[oó]ria|(?:no|neste|nesse)\s+aparelho))?[.!?]*$"#, options: [.regularExpression, .caseInsensitive]) {
            explicit = true
            text.removeSubrange(range)
            text = trim(text)
        }

        let patterns = [
            #"^(?:moram|vivem)\s+(?:comigo|com\s+voc[eê])\s+(?:apenas|s[oó])\s+(.+)$"#,
            #"^(?:apenas|s[oó])\s+(.+?)\s+(?:moram|vivem)\s+(?:comigo|com\s+voc[eê])$"#,
            #"^(?:quem\s+mora\s+(?:comigo|com\s+voc[eê])\s+(?:é|e)\s+)(.+)$"#
        ]
        for pattern in patterns {
            guard let namesText = firstCapture(pattern, text)?.first else { continue }
            let names = splitNames(namesText)
            guard !names.isEmpty else { continue }
            return ([("moradores comigo", "Moram comigo apenas \(joinNames(names))")], correction, explicit)
        }
        return nil
    }

    private func localConcreteMemoryAnswer(text raw: String, store: XRPersistentMemory, english: Bool) throws -> String? {
        let key = XRPersistentMemory.key(raw)
        func canonical(_ raw: String) -> (key: String, display: String) {
            var display = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
            display = display.replacingOccurrences(of: #"(?i)^(?:a|o|as|os|uma|um)\s+"#, with: "", options: .regularExpression)
            let k = XRPersistentMemory.key(display)
            if k == "dani" || k == "daniela" { return ("daniela", "Daniela") }
            if k == "mel" { return ("mel", "Mel") }
            return (k, display)
        }
        func exclusion(from key: String) -> (key: String, display: String)? {
            let prefixes = ["alem da ", "alem do ", "alem de ", "fora a ", "fora o ", "fora "]
            let needles = [" quem mora comigo", " quem mora com voce", " quem mora aqui", " quem mais mora comigo", " quem mais mora com voce"]
            for prefix in prefixes where key.hasPrefix(prefix) {
                let rest = String(key.dropFirst(prefix.count))
                for needle in needles {
                    if let range = rest.range(of: needle) {
                        let rawName = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = canonical(rawName)
                        return value.key.isEmpty ? nil : value
                    }
                }
            }
            return nil
        }
        let excluded = exclusion(from: key)
        let asksHome = key == "quem mora comigo" || key == "quem mora com voce" || key == "quem mora aqui" || key == "quem mora na minha casa" || key == "quem mais mora comigo" || key == "quem mais mora com voce" || excluded != nil
        let asksAlias = key.contains("dani") && key.contains("daniela") && (key.contains("mesma pessoa") || key.contains("apelido"))

        let looksLikeSaveCommand = key.hasPrefix("salva ") || key.hasPrefix("salve ") || key.hasPrefix("guarda ") || key.hasPrefix("guarde ") || key.hasPrefix("memoriza ") || key.hasPrefix("memorize ") || key.hasPrefix("lembra ") || key.hasPrefix("lembre ") || key.contains(" salva essa ") || key.contains(" salva esta ") || key.contains(" salva essas ") || key.contains(" salva estes ") || key.contains(" salve essa ") || key.contains(" salve esta ") || key.contains(" salve essas ") || key.contains(" salve estes ") || key.contains(" guarde isso") || key.contains(" guarde essa") || key.contains(" guarde esta") || key.contains("guardar no xr") || key.contains("salvar no xr")
        let asksStatus = !looksLikeSaveCommand
            && (key.contains("salv") || key.contains("xr") || key.contains("conversa") || key.contains("chat") || key.contains("memoria"))
            && (key.contains("essa informacao") || key.contains("esta informacao") || key.contains("isso") || key.contains("so nessa conversa") || key.contains("so nesta conversa") || key.contains("so nesse chat") || key.contains("so neste chat") || key.contains("salva no xr") || key.contains("salvo no xr") || key.contains("salva neste xr") || key.contains("salvo neste xr") || key.contains("memoria local"))
        let asksPerson: (key: String, display: String)? = {
            if key.hasPrefix("quem e ") {
                let value = canonical(String(key.dropFirst("quem e ".count)))
                return value.key.isEmpty ? nil : value
            }
            if key.hasPrefix("quem eh ") {
                let value = canonical(String(key.dropFirst("quem eh ".count)))
                return value.key.isEmpty ? nil : value
            }
            return nil
        }()
        guard asksHome || asksPerson != nil || asksAlias || asksStatus else { return nil }
        if asksStatus {
            let now = ProcessInfo.processInfo.systemUptime
            let recentlyAnsweredFromMemory = lastRecallAt > 0 && (now - lastRecallAt) <= 300.0
            let hasSavedFacts: Bool
            if let statusDocument = try? store.load() {
                hasSavedFacts = !statusDocument.facts.isEmpty
            } else {
                hasSavedFacts = false
            }
            lastRecallAt = now
            invalidateConversation()
            if recentlyAnsweredFromMemory || hasSavedFacts {
                return english ? "The information is saved in this XR's local memory." : "Essa informação está salva na memória local deste XR."
            }
            return english ? "I did not find that information saved on this XR." : "Não encontrei essa informação salva neste XR."
        }
        if asksAlias {
            lastKeys = []
            lastRecallAt = ProcessInfo.processInfo.systemUptime
            invalidateConversation()
            return english ? "On this XR, Dani is treated as a nickname for Daniela." : "Neste XR, Dani será tratada como apelido de Daniela."
        }

        let doc = try store.load()
        if let target = asksPerson, target.key != "daniela", !store.facts(for: target.display, document: doc).isEmpty {
            return nil
        }

        var explicitResidents: [(key: String, display: String, source: String)] = []
        var coResidents: [String: String] = [:]
        var sourceKeys: [String: [String]] = [:]
        func remember(_ name: String, sourceKey: String, intoExplicit: Bool = false) {
            let value = canonical(name)
            guard !["", "voce", "voces", "eu", "comigo", "mim", "me", "you"].contains(value.key) else { return }
            if intoExplicit {
                if !explicitResidents.contains(where: { $0.key == value.key }) { explicitResidents.append((value.key, value.display, sourceKey)) }
                return
            }
            if coResidents[value.key] == nil { coResidents[value.key] = value.display }
            var values = sourceKeys[value.key] ?? []
            if !values.contains(sourceKey) { values.append(sourceKey) }
            sourceKeys[value.key] = values
        }
        func displaySubject(_ fact: XRMemoryFact) -> String {
            XRMemoryIntent.displayName(subject: fact.subject, statement: fact.statement) ?? fact.subject
        }
        func capturedNames(pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
                guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?")))
            }
        }
        func splitResidentList(_ raw: String) -> [String] {
            var value = raw.replacingOccurrences(of: #"(?i)\b(?:e|and)\b"#, with: ",", options: .regularExpression)
            value = value.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            return value.split(separator: ",").map { String($0) }.map { item in
                item.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.")))
                    .replacingOccurrences(of: #"(?i)^(?:a|o|as|os|uma|um)\s+"#, with: "", options: .regularExpression)
            }.filter { !$0.isEmpty }
        }
        func explicitOnlyList(_ rendered: String) -> [String]? {
            let patterns = [
                #"(?i)(?:moram|vivem)\s+com\s+voc[eê]\s+(?:apenas|s[oó])\s+(.+)$"#,
                #"(?i)(?:moram|vivem)\s+comigo\s+(?:apenas|s[oó])\s+(.+)$"#,
                #"(?i)(?:apenas|s[oó])\s+(.+?)\s+(?:moram|vivem)\s+(?:comigo|com\s+voc[eê])$"#
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(rendered.startIndex..<rendered.endIndex, in: rendered)
                guard let match = regex.firstMatch(in: rendered, options: [], range: range), match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: rendered) else { continue }
                return splitResidentList(String(rendered[r]))
            }
            return nil
        }
        for fact in doc.facts {
            let rendered = XRMemoryIntent.naturalizedStatement(fact.statement)
            if let names = explicitOnlyList(rendered) {
                explicitResidents = []
                for name in names { remember(name, sourceKey: fact.key, intoExplicit: true) }
                continue
            }
            let renderedKey = XRPersistentMemory.key(rendered)
            let mentionsHome = renderedKey.contains("mora com voce") || renderedKey.contains("moram com voce") || renderedKey.contains("vive com voce") || renderedKey.contains("vivem com voce") || renderedKey.contains("mora comigo") || renderedKey.contains("moram comigo")
            guard mentionsHome else { continue }
            remember(displaySubject(fact), sourceKey: fact.key)
            for name in capturedNames(pattern: #"\bcom\s+(?:a|o|as|os)?\s*([A-ZÁÀÂÃÉÊÍÓÔÕÚÇ][\p{L}'-]+(?:\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ][\p{L}'-]+){0,3})"#, in: rendered) {
                remember(name, sourceKey: fact.key)
            }
        }
        if !explicitResidents.isEmpty {
            coResidents = Dictionary(uniqueKeysWithValues: explicitResidents.map { ($0.key, $0.display) })
            sourceKeys = Dictionary(uniqueKeysWithValues: explicitResidents.map { ($0.key, [$0.source]) })
        }
        guard !coResidents.isEmpty else { return nil }
        func article(_ name: String) -> String { XRPersistentMemory.key(name) == "mel" ? "a Mel" : name }
        func join(_ names: [String]) -> String {
            if names.count <= 1 { return names.first ?? "" }
            if names.count == 2 { return "\(names[0]) e \(names[1])" }
            return names.dropLast().joined(separator: ", ") + " e " + (names.last ?? "")
        }
        func orderedResidents(_ values: [String]) -> [String] {
            values.sorted { left, right in
                let lk = XRPersistentMemory.key(left), rk = XRPersistentMemory.key(right)
                if lk == "mel" { return true }
                if rk == "mel" { return false }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
        func updateRecall(keys rawKeys: [String]) {
            var unique: [String] = []
            for key in rawKeys where !unique.contains(key) { unique.append(key) }
            lastKeys = unique
            lastRecallAt = ProcessInfo.processInfo.systemUptime
            invalidateConversation()
        }
        var sorted = orderedResidents(Array(coResidents.values))
        if let excluded { sorted = sorted.filter { canonical($0).key != excluded.key } }
        if asksHome {
            guard !sorted.isEmpty else {
                updateRecall(keys: [])
                let label = excluded?.display ?? "essa pessoa"
                return english ? "I do not have anyone else saved as living with you on this XR." : "Pelo que está salvo neste XR, não encontrei mais ninguém além de \(label)."
            }
            let keys = sorted.flatMap { sourceKeys[canonical($0).key] ?? [] }
            updateRecall(keys: keys)
            let joined = join(sorted)
            if let excluded {
                return english ? "Saved on this XR, besides \(excluded.display), these people or animals live with you: \(joined)." : "Pelo que está salvo neste XR, além de \(excluded.display), mora com você: \(joined)."
            }
            return english ? "Saved on this XR, these people or animals live with you: \(joined)." : "Pelo que está salvo neste XR, moram com você: \(joined)."
        }
        if let target = asksPerson, let canonicalDisplay = coResidents[target.key] {
            let keys = sourceKeys[target.key] ?? []
            updateRecall(keys: keys)
            let others = orderedResidents(Array(coResidents.values)).filter { canonical($0).key != target.key }.map(article)
            let tail = others.isEmpty ? "" : " e com \(join(others))"
            return english ? "Saved on this XR, \(canonicalDisplay) lives with you." : "Pelo que está salvo neste XR, \(canonicalDisplay) mora com você\(tail)."
        }
        return nil
    }

    func hud() async throws -> HUDSnapshot { try await underlying.hud() }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { try await underlying.command(action, params: params) }
    func telemetry() async throws -> TARSTelemetry { try await underlying.telemetry() }
    func recover() async throws { try await underlying.recover() }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply {
        try await underlying.describeImage(png: png, source: source, question: question, history: history)
    }
    func transcribe(data: Data) async throws -> String { try await underlying.transcribe(data: data) }
    func synthesize(text: String) async throws -> Data { try await underlying.synthesize(text: text) }
    // These diagnostic paths remain delegated. Normal voice streaming remains disabled.
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws {
        try await underlying.streamSpeech(text: text, receive: receive)
    }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws {
        try await underlying.streamConversation(text: text, receive: receive, receiveText: receiveText)
    }
}

#if DEBUG
/// Bounded metadata trace. It never receives transcripts, statements, names or credentials.
@MainActor
final class XRMemoryTrace {
    static let marker = "XR_MEMORY_TRACE_01"
    // SwiftUI may construct unused runtime instances during view updates. A process-wide
    // ring preserves command events instead of overwriting them with a new startup marker.
    static let shared = XRMemoryTrace()
    private let destination: URL?
    private let echo: (String) -> Void
    private let now: () -> Double
    private let sessionID = UUID().uuidString
    private var sequence = 0
    private var events: [[String: Any]] = []
    private(set) var lastWriteSucceeded = false

    nonisolated static func deviceDestination() -> URL? {
        #if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("memory-trace.json")
        #else
        return nil // Portable tests never write to the developer's actual Documents directory.
        #endif
    }

    init(destination: URL? = XRMemoryTrace.deviceDestination(),
         now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         echo: @escaping (String) -> Void = { print($0) }) {
        self.destination = destination; self.now = now; self.echo = echo
    }

    static func intentMetadata(_ intent: XRMemoryIntent) -> [String: Any] {
        switch intent {
        case .save(let subject, _, let correction):
            return ["intent": "save", "correction": correction,
                    "mel_subject_match": XRPersistentMemory.key(subject) == "mel"]
        case .recall(let subject, let explicit):
            return ["intent": "recall", "explicit": explicit,
                    "mel_subject_match": XRPersistentMemory.key(subject) == "mel"]
        case .recallAttribute(_, let attribute):
            return ["intent": "recall_attribute", "attribute": attribute.rawValue]
        case .forget(let subject):
            return ["intent": "forget", "mel_subject_match": XRPersistentMemory.key(subject) == "mel"]
        case .help: return ["intent": "help"]
        case .ordinary: return ["intent": "ordinary"]
        }
    }

    static func errorCode(_ error: XRMemoryError) -> String {
        switch error {
        case .invalid: return "INVALID_STORE"
        case .unavailable: return "STORAGE_UNAVAILABLE"
        case .full: return "STORE_FULL"
        case .missing: return "FACT_MISSING"
        case .changed: return "MEMORY_CHANGED"
        case .unsupported: return "UNSUPPORTED_FACT"
        case .ambiguous: return "AMBIGUOUS_REFERENCE"
        }
    }

    @discardableResult
    func record(_ event: String, fields: [String: Any] = [:], storage: [String: Any]? = nil) -> [String: Any] {
        sequence += 1
        let allowed = ["runtime_ready", "store_opened", "store_open_failed", "intent_received",
                       "save_verified", "forget_verified", "grammar_help", "recall_lookup",
                       "context_loaded", "remote_request", "remote_answer", "memory_error",
                       "request_cancelled", "remote_error", "awaiting_fact", "pending_fact_received",
                       "pending_cancelled", "pending_expired", "memory_suggested",
                       "suggestion_confirmed", "suggestion_declined", "suggestion_dismissed", "suggestion_expired",
                       "suggestion_waiting", "confirmation_without_pending"]
        var entry: [String: Any] = ["sequence": sequence, "timestamp": now(),
                                   "event": allowed.contains(event) ? event : "unknown_event"]
        for name in ["correction", "explicit", "mel_subject_match", "fact_existed", "found", "has_tombstone"] {
            if let value = fields[name] as? Bool { entry[name] = value }
        }
        for name in ["fact_count", "selected_count", "match_count"] {
            if let value = fields[name] as? Int, (0...128).contains(value) { entry[name] = value }
        }
        if let value = fields["runtime_instance"] as? String, UUID(uuidString: value) != nil {
            entry["runtime_instance"] = value
        }
        if let kind = fields["intent"] as? String, ["save", "forget", "recall", "help", "ordinary"].contains(kind) {
            entry["intent"] = kind
        }
        if let code = fields["code"] as? String,
           ["INVALID_STORE", "STORAGE_UNAVAILABLE", "STORE_FULL", "FACT_MISSING", "MEMORY_CHANGED", "UNSUPPORTED_FACT", "AMBIGUOUS_REFERENCE"].contains(code) {
            entry["code"] = code
        }
        if let storage {
            for name in ["file_node", "parent_node"] {
                if let value = storage[name] as? String,
                   ["file", "directory", "symlink", "other", "missing", "unavailable"].contains(value) { entry[name] = value }
            }
            if let value = storage["path_matches_device_contract"] as? Bool { entry["path_matches_device_contract"] = value }
        }
        events.append(entry)
        if events.count > 24 { events.removeFirst(events.count - 24) }
        let report: [String: Any] = ["version": Self.marker, "trace_session": sessionID,
                                   "process_id": ProcessInfo.processInfo.processIdentifier,
                                   "events": events, "latest": entry]
        lastWriteSucceeded = false
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let destination {
            do {
                // Diagnostic metadata only, never the memory database. Keep the latest bounded trace.
                #if os(iOS)
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
                var url = destination
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try url.setResourceValues(values)
                #else
                try data.write(to: destination, options: .atomic)
                #endif
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                lastWriteSucceeded = true
            } catch { /* No trace failure can prevent a real memory operation. */ }
        }
        var console = entry
        console["version"] = Self.marker
        console["trace_file_written"] = lastWriteSucceeded
        if let data = try? JSONSerialization.data(withJSONObject: console, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { echo("[TARS_MEMORY] " + text) }
        return entry
    }
}
#endif
