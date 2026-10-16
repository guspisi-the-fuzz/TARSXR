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

    private let prepareConversation: (@MainActor (String) -> Void)?
    private let observeRecall: (@MainActor (String, String, XRMemoryDocument) -> Void)?
    private let logicalRecall: (@MainActor (String, XRMemoryDocument) async throws -> String?)?
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
         pendingState: XRMemoryPendingState? = nil,
         logicalRecall: (@MainActor (String, XRMemoryDocument) async throws -> String?)? = nil,
         observeRecall: (@MainActor (String, String, XRMemoryDocument) -> Void)? = nil,
         prepareConversation: (@MainActor (String) -> Void)? = nil) {
        self.prepareConversation = prepareConversation
        self.observeRecall = observeRecall
        self.logicalRecall = logicalRecall
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
        prepareConversation?(text)
        let before = try? storage().load()
        let answer = try await converseImpl(text:text, language:language, context:context)
        try Task.checkCancellation()
        if context?["internal_wake_summary"] as? Bool != true,
           !SpokenRequest.isServiceQuery(text), XRMemoryIntent.isQuestionLike(text),
           let before, let after = try? storage().load(),
           before.ownerID == after.ownerID, before.revision == after.revision {
            observeRecall?(text,answer,after)
        }
        return answer
    }

    private func converseImpl(text: String, language: String, context: [String: Any]?) async throws -> String {
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
        if !internalWake,
           !SpokenRequest.isServiceQuery(text),
           localRelationNameRecallSubject(text: text) != nil {
            do {
                if let relationRecall = try localRelationNameRecall(text: text, store: store, english: english) {
                    invalidateConversation()
                    return relationRecall
                }
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation()
                return error.localizedDescription
            }
        }

        if !internalWake, !SpokenRequest.isServiceQuery(text), pendingState.fact == nil, pendingState.suggestion == nil, let logicalRecall {
            let eligible: Bool
            switch XRMemoryIntent.parse(text) {
            // Explicit memory reads are deterministic and must be answered by the
            // local XR store first. The model/logical recall can mix nearby facts
            // and produce wrong associations like answering Daniela with Mel.
            case .recall, .recallAttribute: eligible = false
            case .ordinary: eligible = XRMemoryIntent.isQuestionLike(text)
            default: eligible = false
            }
            if eligible {
                do {
                    let before = try store.load()
                    if let answer = try await logicalRecall(text,before) {
                        try Task.checkCancellation()
                        guard try store.load().revision == before.revision else { throw XRMemoryError.changed }
                        invalidateConversation()
                        return answer
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    return "Não consegui concluir essa consulta à memória com segurança. Nenhuma informação foi alterada."
                }
            }
        }
        if !internalWake, let relationName = localRelationNameCorrection(text: text) {
            do {
                let fact = try store.save(subject: relationName.subject,
                                          statement: relationName.statement,
                                          correction: true)
                traceMemory("save_verified", fields: ["correction": true])
                lastKeys = [fact.key]
                lastRecallAt = ProcessInfo.processInfo.systemUptime
                invalidateConversation()
                return english ? "Saved on this XR: \(fact.statement)."
                    : "Salvei neste XR: \(XRMemoryIntent.naturalizedStatement(fact.statement))"
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation()
                return error.localizedDescription
            }
        }

        if !internalWake, let relationForgetSubject = localRelationNameForget(text: text) {
            do {
                let existed = try store.forget(subject: relationForgetSubject)
                traceMemory("forget_verified", fields: ["fact_existed": existed])
                lastKeys = []
                lastRecallAt = 0
                invalidateConversation()

                if existed {
                    return english ? "Forgot it on this XR." : "Apaguei neste XR."
                }

                return english ? "I don't have that saved on this XR."
                    : "Não tenho isso salvo neste XR."
            } catch let error as XRMemoryError {
                #if DEBUG
                traceMemory("memory_error", fields: ["code": XRMemoryTrace.errorCode(error)])
                #else
                traceMemory("memory_error")
                #endif
                invalidateConversation()
                return error.localizedDescription
            }
        }

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
        if !internalWake,
           XRMemoryIntent.explicitEntityAttributeFacts(text) == nil,
           let rename = XRMemoryIntent.renameCorrection(text) {
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
        if !internalWake && pendingState.fact == nil && localConfirmsPendingSuggestion(text) {
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

    private func localRelationNameRecallSubject(text raw: String) -> String? {
        let key = XRPersistentMemory.key(raw)

        switch key {
        case "qual o nome da minha mae",
             "qual e o nome da minha mae",
             "qual o nome de minha mae",
             "qual e o nome de minha mae",
             "voce lembra o nome da minha mae",
             "lembra o nome da minha mae",
             "voce lembra o nome de minha mae",
             "lembra o nome de minha mae",
             "como minha mae se chama",
             "como se chama minha mae",
             "e qual o nome da minha mae",
             "como chama minha mae",
             "voce lembra do nome da minha mae",
             "quem e a minha mae",
             "o que voce sabe sobre minha mae",
             "como e o nome da minha mae",
             "por favor qual o nome da minha mae":
            return "minha mãe"

        case "qual o nome do meu pai",
             "qual e o nome do meu pai",
             "qual o nome de meu pai",
             "qual e o nome de meu pai",
             "voce lembra o nome do meu pai",
             "lembra o nome do meu pai",
             "voce lembra o nome de meu pai",
             "lembra o nome de meu pai",
             "como meu pai se chama",
             "como se chama meu pai",
             "e qual o nome do meu pai",
             "como chama meu pai",
             "voce lembra do nome do meu pai",
             "quem e o meu pai",
             "o que voce sabe sobre meu pai",
             "como e o nome do meu pai",
             "por favor qual o nome do meu pai":
            return "meu pai"

        default:
            return nil
        }
    }

    private func localRelationNameRecall(text raw: String, store: XRPersistentMemory, english: Bool) throws -> String? {
        guard let subject = localRelationNameRecallSubject(text: raw) else { return nil }

        let document = try store.load()
        let matches = localExactRelationNameFacts(subject: subject, document: document)
        traceMemory("recall_lookup", fields: [
            "fact_count": document.facts.count,
            "found": !matches.isEmpty,
            "match_count": matches.count
        ])

        if matches.isEmpty {
            lastKeys = []
            lastRecallAt = 0

            if english {
                return subject == "minha mãe"
                    ? "I don't have your mother's name saved on this XR."
                    : "I don't have your father's name saved on this XR."
            }

            return subject == "minha mãe"
                ? "Não tenho o nome da sua mãe salvo neste XR."
                : "Não tenho o nome do seu pai salvo neste XR."
        }

        if matches.count > 1 {
            lastKeys = matches.map { $0.key }
            lastRecallAt = ProcessInfo.processInfo.systemUptime

            let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let options = matches.enumerated().map { index, fact in
                let label = index < letters.count ? String(letters[index]) : "\(index + 1)"
                return "\(label)) \(localRelationNameValue(fact: fact, subject: subject))"
            }.joined(separator: "\n\n")

            return english
                ? "I found more than one possible name:\n\n\(options)\n\nWhich one is correct?"
                : "Encontrei mais de uma possibilidade para nome:\n\n\(options)\n\nQual é a correta?"
        }

        guard let fact = matches.first else { return nil }

        lastKeys = [fact.key]
        lastRecallAt = ProcessInfo.processInfo.systemUptime

        let value = localRelationNameValue(fact: fact, subject: subject)

        if english {
            return subject == "minha mãe"
                ? "Your mother's name is \(value)."
                : "Your father's name is \(value)."
        }

        return subject == "minha mãe"
            ? "Sua mãe se chama \(value)."
            : "Seu pai se chama \(value)."
    }

    private func localExactRelationNameFacts(subject: String, document: XRMemoryDocument) -> [XRMemoryFact] {
        let targetKey = XRPersistentMemory.key(subject)

        return document.facts.filter { fact in
            let subjectKey = XRPersistentMemory.key(fact.subject)
            let statementKey = XRPersistentMemory.key(fact.statement)

            if subjectKey == targetKey { return true }
            if localCapturedRelationName(statement: fact.statement, subject: subject) != nil {
                return true
            }

            if targetKey == "minha mae" {
                if subjectKey == "nome da minha mae" || subjectKey == "nome de minha mae" {
                    return true
                }

                return statementKey.hasSuffix(" e minha mae")
                    || statementKey.hasPrefix("minha mae se chama ")
                    || statementKey.contains(" minha mae se chama ")
                    || statementKey.hasPrefix("nome da minha mae e ")
                    || statementKey.hasPrefix("o nome da minha mae e ")
                    || statementKey.hasPrefix("nome de minha mae e ")
                    || statementKey.hasPrefix("o nome de minha mae e ")
                    || statementKey.contains(" nome da minha mae e ")
                    || statementKey.contains(" o nome da minha mae e ")
                    || statementKey.contains(" nome de minha mae e ")
                    || statementKey.contains(" o nome de minha mae e ")
            }

            if targetKey == "meu pai" {
                if subjectKey == "nome do meu pai" || subjectKey == "nome de meu pai" {
                    return true
                }

                return statementKey.hasSuffix(" e meu pai")
                    || statementKey.hasPrefix("meu pai se chama ")
                    || statementKey.contains(" meu pai se chama ")
                    || statementKey.hasPrefix("nome do meu pai e ")
                    || statementKey.hasPrefix("o nome do meu pai e ")
                    || statementKey.hasPrefix("nome de meu pai e ")
                    || statementKey.hasPrefix("o nome de meu pai e ")
                    || statementKey.contains(" nome do meu pai e ")
                    || statementKey.contains(" o nome do meu pai e ")
                    || statementKey.contains(" nome de meu pai e ")
                    || statementKey.contains(" o nome de meu pai e ")
            }

            return false
        }
    }

    private func localRelationNameValue(fact: XRMemoryFact, subject: String) -> String {
        if let captured = localCapturedRelationName(statement: fact.statement, subject: subject) {
            return captured
        }

        return fact.subject
    }

    private func localCapturedRelationName(statement: String, subject: String) -> String? {
        let subjectKey = XRPersistentMemory.key(subject)
        let patterns: [String]

        if subjectKey == "minha mae" {
            patterns = [
                #"^\s*(?:a\s+)?minha\s+m(?:ãe|ae)\s+(?:é|e|eh|(?:se\s+)?chama(?:\s*-\s*se)?)\s+(.+?)\s*[.!?]?\s*$"#,
                #"^\s*(?:o\s+)?nome\s+d(?:a|e)\s+minha\s+m(?:ãe|ae)\s+(?:é|e|eh|(?:se\s+)?chama(?:\s*-\s*se)?)\s+(.+?)\s*[.!?]?\s*$"#
            ]
        } else if subjectKey == "meu pai" {
            patterns = [
                #"^\s*(?:o\s+)?meu\s+pai\s+(?:é|e|eh|(?:se\s+)?chama(?:\s*-\s*se)?)\s+(.+?)\s*[.!?]?\s*$"#,
                #"^\s*(?:o\s+)?nome\s+d(?:o|e)\s+meu\s+pai\s+(?:é|e|eh|(?:se\s+)?chama(?:\s*-\s*se)?)\s+(.+?)\s*[.!?]?\s*$"#
            ]
        } else {
            return nil
        }

        let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            guard let match = regex.firstMatch(in: statement, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: statement) else {
                continue
            }

            let value = String(statement[valueRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))

            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func localRelationNameForget(text raw: String) -> String? {
        let key = XRPersistentMemory.key(raw)

        let isForget = key.hasPrefix("esqueca ")
            || key.hasPrefix("esquece ")
            || key.hasPrefix("apague ")
            || key.hasPrefix("apaga ")
            || key.hasPrefix("remova ")
            || key.hasPrefix("remove ")

        guard isForget else { return nil }

        if key.contains("nome da minha mae") || key.contains("nome de minha mae") {
            return "minha mãe"
        }

        if key.contains("nome do meu pai") || key.contains("nome de meu pai") {
            return "meu pai"
        }

        return nil
    }

    private func localRelationNameCorrection(text raw: String) -> (subject: String, statement: String)? {
        let key = XRPersistentMemory.key(raw)
        guard key.hasPrefix("corrija ") || key.hasPrefix("corrige ") || key.hasPrefix("correcao ") || key.hasPrefix("correção ") else {
            return nil
        }

        let patterns: [(pattern: String, subject: String, prefix: String)] = [
            (#"(?i)\bminha\s+m(?:ãe|ae)\s+(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#, "minha mãe", "Minha mãe se chama "),
            (#"(?i)\bnome\s+d[ae]\s+minha\s+m(?:ãe|ae)\s+(?:chama(?:\s*-\s*se)?|é|e|eh|:)\s+(.+?)(?:[.!?]|$)"#, "minha mãe", "Minha mãe se chama "),
            (#"(?i)\bmeu\s+pai\s+(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#, "meu pai", "Meu pai se chama "),
            (#"(?i)\bnome\s+d[eo]\s+meu\s+pai\s+(?:chama(?:\s*-\s*se)?|é|e|eh|:)\s+(.+?)(?:[.!?]|$)"#, "meu pai", "Meu pai se chama ")
        ]

        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: raw) else { continue }

            let name = String(raw[valueRange])
                .replacingOccurrences(of: #"(?i)\b(?:guarde|guarda|grave|grava|salve|salva)\s+(?:isso|essa|esta|na memória|na memoria).*$"#,
                                       with: "",
                                       options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))

            let nameKey = XRPersistentMemory.key(name)
            guard !nameKey.isEmpty,
                  nameKey != "minha mae",
                  nameKey != "meu pai",
                  name.count <= 80 else { continue }

            return (item.subject, item.prefix + name)
        }

        let normalizedCases: [(needle: String, subject: String, prefix: String)] = [
            ("minha mae se chama ", "minha mãe", "Minha mãe se chama "),
            ("nome da minha mae chama se ", "minha mãe", "Minha mãe se chama "),
            ("nome da minha mae e ", "minha mãe", "Minha mãe se chama "),
            ("meu pai se chama ", "meu pai", "Meu pai se chama "),
            ("nome do meu pai chama se ", "meu pai", "Meu pai se chama "),
            ("nome do meu pai e ", "meu pai", "Meu pai se chama ")
        ]

        for item in normalizedCases {
            guard let range = key.range(of: item.needle) else { continue }
            let rawName = String(key[range.upperBound...])
                .replacingOccurrences(of: #"(?i)\b(?:guarde|guarda|grave|grava|salve|salva)\b.*$"#,
                                       with: "",
                                       options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))

            let nameKey = XRPersistentMemory.key(rawName)
            guard !nameKey.isEmpty,
                  nameKey != "minha mae",
                  nameKey != "meu pai",
                  nameKey.count <= 80 else { continue }

            let name = rawName.capitalized(with: Locale(identifier: "pt_BR"))
            return (item.subject, item.prefix + name)
        }

        return nil
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
        let profileDocument = try store.load()
        if XRMemoryProfileResolverV1.shouldHandle(text: raw, document: profileDocument),
           let profileAnswer = XRMemoryProfileResolverV1.answer(text: raw, document: profileDocument, english: english) {
            let profileKeys = XRMemoryProfileResolverV1.followUpKeys(text: raw, document: profileDocument)
            if !profileKeys.isEmpty {
                lastKeys = profileKeys
                lastRecallAt = ProcessInfo.processInfo.systemUptime
            }
            return profileAnswer
        }

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
    // Audio output remains delegated; conversation routing always passes through memory.
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws {
        try await underlying.streamSpeech(text: text, receive: receive)
    }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws {
        // Use the same memory/topic routing for both voice output paths.
        let speech = try await converse(text:text, language:"auto", context:nil)
        try Task.checkCancellation()
        receiveText(speech)
        try await underlying.streamSpeech(text:speech, receive:receive)
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


// MARK: - XR Memory Profile Resolver V1
// Read-only relational resolver. It does not migrate the memory schema yet;
// it turns existing explicit facts into a temporary entity profile before
// falling back to older sentence/alias recall or the model.
@MainActor
private enum XRMemoryProfileResolverV1 {
    struct Profile {
        var canonical: String
        var labels: Set<String> = []
        var names: Set<String> = []
        var birthDates: Set<String> = []
        var deathDates: Set<String> = []
        var relations: Set<String> = []
        var residence: Set<String> = []
        var notes: [String] = []
    }

    static func shouldHandle(text rawText: String, document: XRMemoryDocument) -> Bool {
        let query = XRPersistentMemory.key(rawText)
        guard let target = targetEntity(from: query) else { return false }

        if target == "meu pai" || target == "minha mãe" {
            return asksName(query) || asksBirth(query) || asksWhoOrBroad(query)
        }

        // Não roubar fluxos antigos ainda:
        // - Mel já passa nos testes antigos.
        // - Daniela não deve ser inferida apenas por aparecer dentro do fato da Mel.
        return false
    }

    static func followUpKeys(text rawText: String, document: XRMemoryDocument) -> [String] {
        let query = XRPersistentMemory.key(rawText)
        guard let target = targetEntity(from: query) else { return [] }

        let targetKey = XRPersistentMemory.key(target)

        // Prefer exact relation references from the schema-v1 resolver.
        // This keeps "minha mãe" separate from "mãe da Daniela".
        let relationMatches = document.facts.filter { fact in
            XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement).contains(targetKey)
        }

        if !relationMatches.isEmpty {
            return relationMatches.map { $0.key }
        }

        // Fallback for older alias shapes when the profile extracted a single name.
        let profile = buildProfile(target: target, document: document)

        if let name = profile.names.sorted().first {
            let nameKey = XRPersistentMemory.key(name)
            if document.facts.contains(where: { $0.key == nameKey }) {
                return [nameKey]
            }
        }

        return []
    }

    static func answer(text rawText: String, document: XRMemoryDocument, english: Bool) -> String? {
        let query = XRPersistentMemory.key(rawText)
        guard let target = targetEntity(from: query) else { return nil }

        let profile = buildProfile(target: target, document: document)
        guard hasSignal(profile) else { return nil }

        if asksName(query), profile.names.count > 1 {
            return ambiguity(field: "nome", values: profile.names)
        }
        if asksBirth(query), profile.birthDates.count > 1 {
            return ambiguity(field: "data de nascimento", values: profile.birthDates)
        }

        if asksName(query) {
            if let name = profile.names.sorted().first {
                return target == "meu pai" ? "Seu pai se chama \(name)." :
                    target == "minha mãe" ? "Sua mãe se chama \(name)." :
                    "O nome salvo é \(name)."
            }
            return absenceForName(target: target)
        }

        if asksBirth(query) {
            if let birth = profile.birthDates.sorted().first {
                return target == "meu pai" ? "Seu pai nasceu em \(birth)." :
                    target == "minha mãe" ? "Sua mãe nasceu em \(birth)." :
                    "\(display(target)) nasceu em \(birth)."
            }
            return "Não tenho a data de nascimento salva para \(display(target))."
        }

        if asksWhoOrBroad(query) {
            return broadAnswer(target: target, profile: profile)
        }

        return nil
    }

    private static func targetEntity(from query: String) -> String? {
        let padded = " " + query + " "

        if padded.contains(" mae da daniela ") || padded.contains(" mae de daniela ") ||
            padded.contains(" mãe da daniela ") || padded.contains(" mãe de daniela ") {
            return nil
        }

        if padded.contains(" meu pai ") {
            return "meu pai"
        }

        if padded.contains(" minha mae ") || padded.contains(" minha mãe ") {
            return "minha mãe"
        }

        if padded.contains(" daniela ") || padded.contains(" frighetto ") {
            return "daniela"
        }

        if padded.contains(" mel ") {
            return "mel"
        }

        return nil
    }

    private static func buildProfile(target: String, document: XRMemoryDocument) -> Profile {
        let targetKey = XRPersistentMemory.key(target)
        var profile = Profile(canonical: target)

        for fact in document.facts {
            let subjectKey = XRPersistentMemory.key(fact.subject)
            let statementKey = XRPersistentMemory.key(fact.statement)
            let allKeys = XRMemoryIntent.referenceKeys(subject: fact.subject, statement: fact.statement)

            let directHit = subjectKey == targetKey || allKeys.contains(targetKey)
            let mentionHit = mentions(target: target, key: statementKey) || mentions(target: target, key: subjectKey)

            guard directHit || mentionHit else { continue }

            profile.labels.insert(fact.subject)
            profile.notes.append(fact.statement)

            if let name = extractName(target: target, subject: fact.subject, statement: fact.statement) {
                profile.names.insert(name)
            }
            if let birth = extractDate(kind: .birth, statement: fact.statement) {
                profile.birthDates.insert(birth)
            }
            if let death = extractDate(kind: .death, statement: fact.statement) {
                profile.deathDates.insert(death)
            }
            if statementKey.contains(" namorada") || statementKey.contains("minha namorada") {
                profile.relations.insert("namorada")
            }
            if statementKey.contains(" gata") || statementKey.contains(" gato") {
                profile.relations.insert("gata")
            }
            if statementKey.contains(" mora ") || statementKey.contains("moram") || statementKey.contains("com voce") || statementKey.contains("com você") {
                profile.residence.insert(cleanSentence(fact.statement))
            }
        }

        return profile
    }

    private enum DateKind { case birth, death }

    private static func extractDate(kind: DateKind, statement: String) -> String? {
        let patterns: [String]
        switch kind {
        case .birth:
            patterns = [
                #"(?i)\bnasceu\s+em\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bnasceu\s+no\s+dia\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bnasceu\s+dia\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bdata\s+de\s+nascimento\s*(?:é|e|eh|:)?\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\banivers[aá]rio\s*(?:é|e|eh|:)?\s+(.+?)(?:[.!?]|$)"#
            ]
        case .death:
            patterns = [
                #"(?i)\bfaleceu\s+em\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bmorreu\s+em\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bdata\s+de\s+falecimento\s*(?:é|e|eh|:)?\s+(.+?)(?:[.!?]|$)"#
            ]
        }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)
            guard let match = regex.firstMatch(in: statement, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: statement) else { continue }
            let value = cleanValue(String(statement[valueRange]))
            // Legacy statements may repeat a date with "dia" or a possessive prefix.
            // Compare the actual date instead of treating the surrounding prose as data.
            if let dateRange = value.range(of: #"\b\d{1,2}\s+de\s+[\p{L}]+\s+de\s+\d{4}\b"#, options:.regularExpression) {
                return String(value[dateRange]).lowercased()
            }
            return value
        }
        return nil
    }

    private static func extractName(target: String, subject: String, statement: String) -> String? {
        let key = XRPersistentMemory.key(statement)
        let targetKey = XRPersistentMemory.key(target)

        func valid(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let value = cleanName(raw)
            let valueKey = XRPersistentMemory.key(value)
            guard !valueKey.isEmpty else { return nil }
            guard valueKey != targetKey else { return nil }
            guard valueKey != "nome da minha mae" && valueKey != "nome do meu pai" else { return nil }
            return value
        }

        // Prefer the existing parser when it already knows how to extract a display name.
        if let display = XRMemoryIntent.displayName(subject: subject, statement: statement),
           let value = valid(display) {
            return value
        }

        let rawPatterns: [String]
        switch target {
        case "meu pai":
            rawPatterns = [
                #"(?i)\bmeu\s+pai\s+(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bnome\s+d[eo]\s+meu\s+pai\s+(?:chama(?:\s*-\s*se)?|é|e|eh|:)\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bmeu\s+pai\s+(?:é|eh)\s+(.+?)(?:[.!?]|$)"#
            ]
        case "minha mãe":
            rawPatterns = [
                #"(?i)\bminha\s+m(?:ãe|ae)\s+(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bnome\s+d[ae]\s+minha\s+m(?:ãe|ae)\s+(?:chama(?:\s*-\s*se)?|é|e|eh|:)\s+(.+?)(?:[.!?]|$)"#,
                #"(?i)\bminha\s+m(?:ãe|ae)\s+(?:é|eh)\s+(.+?)(?:[.!?]|$)"#
            ]
        case "daniela":
            rawPatterns = [
                #"(?i)\b(daniela\s+frighetto)\b"#,
                #"(?i)\bdaniela\s+(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#
            ]
        default:
            rawPatterns = [
                #"(?i)\b(?:se\s+)?chama(?:\s*-\s*se)?\s+(.+?)(?:[.!?]|$)"#
            ]
        }

        for pattern in rawPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(statement.startIndex..<statement.endIndex, in: statement)
            guard let match = regex.firstMatch(in: statement, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: statement),
                  let value = valid(String(statement[valueRange])) else { continue }
            return value
        }

        // Normalized fallback for decomposed accents / ASR variants.
        let normalizedPatterns: [String]
        switch target {
        case "meu pai":
            normalizedPatterns = [
                #"meu pai(?: se)? chama(?: se)? (.+)$"#,
                #"nome do meu pai(?: chama se| e| eh|:) (.+)$"#,
                #"meu pai e (.+)$"#
            ]
        case "minha mãe":
            normalizedPatterns = [
                #"minha mae(?: se)? chama(?: se)? (.+)$"#,
                #"nome da minha mae(?: chama se| e| eh|:) (.+)$"#,
                #"minha mae e (.+)$"#
            ]
        default:
            normalizedPatterns = []
        }

        for pattern in normalizedPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            guard let match = regex.firstMatch(in: key, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: key) else { continue }
            let candidate = cleanName(String(key[valueRange])).capitalized(with: Locale(identifier: "pt_BR"))
            if let value = valid(candidate) { return value }
        }

        // Older alias shape: "Anete é minha mãe" / "Orlando é meu pai".
        if target == "meu pai", key.hasSuffix(" e meu pai") {
            if let value = valid(statement.components(separatedBy: " é ").first ?? "") { return value }
            let raw = String(key.dropLast(" e meu pai".count)).capitalized(with: Locale(identifier: "pt_BR"))
            return valid(raw)
        }

        if target == "minha mãe", key.hasSuffix(" e minha mae") {
            if let value = valid(statement.components(separatedBy: " é ").first ?? "") { return value }
            let raw = String(key.dropLast(" e minha mae".count)).capitalized(with: Locale(identifier: "pt_BR"))
            return valid(raw)
        }

        return nil
    }

    private static func broadAnswer(target: String, profile: Profile) -> String {
        let name = profile.names.sorted().first
        let birth = profile.birthDates.sorted().first
        let death = profile.deathDates.sorted().first

        if target == "meu pai" {
            var parts: [String] = []
            if let name { parts.append("se chama \(name)") }
            if let birth { parts.append("nasceu em \(birth)") }
            if let death { parts.append("faleceu em \(death)") }
            if !parts.isEmpty { return "Seu pai \(join(parts))." }
        }

        if target == "minha mãe" {
            var parts: [String] = []
            if let name { parts.append("se chama \(name)") }
            if let birth { parts.append("nasceu em \(birth)") }
            if let death { parts.append("faleceu em \(death)") }
            if !parts.isEmpty { return "Sua mãe \(join(parts))." }
        }

        if target == "daniela" {
            var parts: [String] = []
            if let name { parts.append(name) }
            if profile.relations.contains("namorada") { parts.append("é sua namorada") }
            if profile.residence.contains(where: { XRPersistentMemory.key($0).contains("mora") || XRPersistentMemory.key($0).contains("com voce") }) {
                parts.append("mora com você e com a Mel")
            }
            if !parts.isEmpty {
                if parts.count == 1 { return "A Daniela \(parts[0])." }
                let first = parts.removeFirst()
                return "A \(first) \(join(parts))."
            }
            return "A Daniela aparece na memória como alguém relacionada à sua casa, mas ainda não tenho um perfil completo dela."
        }

        if target == "mel" {
            if profile.relations.contains("gata") {
                if profile.residence.isEmpty {
                    return "A Mel é uma gata."
                }
                return "A Mel é uma gata que mora com você e com a Daniela."
            }
        }

        if let note = profile.notes.first {
            return cleanSentence(note)
        }

        return "Tenho referências salvas sobre \(display(target)), mas ainda não consegui montar um perfil limpo."
    }

    private static func ambiguity(field: String, values: Set<String>) -> String {
        let sorted = values.sorted()
        let options = sorted.enumerated().map { index, value in
            "\(Character(UnicodeScalar(65 + index)!))) \(value)"
        }.joined(separator: "\n")
        return "Encontrei mais de uma possibilidade para \(field):\n\(options)\nQual é a correta?"
    }

    private static func hasSignal(_ profile: Profile) -> Bool {
        !profile.names.isEmpty || !profile.birthDates.isEmpty || !profile.deathDates.isEmpty ||
        !profile.relations.isEmpty || !profile.residence.isEmpty || !profile.notes.isEmpty
    }

    private static func mentions(target: String, key: String) -> Bool {
        switch target {
        case "meu pai": return key.contains("pai")
        case "minha mãe": return key.contains("mae")
        case "daniela": return key.contains("daniela") || key.contains("frighetto")
        case "mel": return key.contains("mel")
        default: return key.contains(XRPersistentMemory.key(target))
        }
    }

    private static func asksName(_ key: String) -> Bool {
        key.contains(" nome ") || key.hasPrefix("nome ") || key.contains(" chama") || key.contains("se chama")
    }

    private static func asksBirth(_ key: String) -> Bool {
        key.contains(" nascimento") || key.contains(" aniversario") || key.contains(" nasceu")
    }

    private static func asksWhoOrBroad(_ key: String) -> Bool {
        key.contains(" quem ") || key.hasPrefix("quem ") ||
        key.contains(" sabe ") || key.contains("sobre ") ||
        key.contains(" o que voce sabe") || key.contains("que voce sabe")
    }

    private static func absenceForName(target: String) -> String {
        switch target {
        case "meu pai": return "Não tenho o nome do seu pai salvo."
        case "minha mãe": return "Não tenho o nome da sua mãe salvo."
        case "daniela": return "Não tenho o nome completo da Daniela salvo."
        case "mel": return "Não tenho outro nome salvo para a Mel."
        default: return "Não tenho esse nome salvo."
        }
    }

    private static func display(_ target: String) -> String {
        switch target {
        case "meu pai": return "seu pai"
        case "minha mãe": return "sua mãe"
        case "daniela": return "a Daniela"
        case "mel": return "a Mel"
        default: return target
        }
    }

    private static func join(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " e " + (parts.last ?? "")
    }

    private static func cleanValue(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)\b(?:guarde|guarda|grave|grava|salve|salva)\s+(?:isso|essa|esta|na memória|na memoria).*$"#,
                                   with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))
    }

    private static func cleanName(_ value: String) -> String {
        cleanValue(value)
            .replacingOccurrences(of: #"(?i)\b(?:é|e|eh)\s+(?:meu pai|minha mãe|minha mae|minha namorada|meu namorado).*$"#,
                                   with: "",
                                   options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?\n\t"))
    }

    private static func cleanSentence(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
