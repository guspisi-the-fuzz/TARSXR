import Foundation

@MainActor private final class ConversationFixture: TARSRuntime {
    var contexts: [[String: Any]] = []
    var response = "Uma resposta geral de teste."
    var wait: CheckedContinuation<String, Error>?
    var paused = false
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("conversation must never actuate") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("conversation must never recover safety") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { preconditionFailure("no microphone") }
    func synthesize(text: String) async throws -> Data { Data(text.utf8) }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        contexts.append(context ?? [:])
        if paused { return try await withCheckedThrowingContinuation { wait = $0 } }
        return response
    }
    var dialogue: [[String: Any]] { contexts.last?["xr_dialogue"] as? [[String: Any]] ?? [] }
}

@main struct ConversationContinuityChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        func waitUntil(_ condition: () -> Bool, _ label: String) async {
            for _ in 0..<1000 { if condition() { return }; try? await Task.sleep(for: .milliseconds(1)) }
            preconditionFailure("Asynchronous fixture stalled: " + label)
        }
        var ledger = ConversationContext()
        ledger.synchronize(owner: "synthetic-owner", revision: "r1")
        ledger.append(question: "O que vê?", answer: "Uma tela.", source: .camera, now: 100, capturedAt: 98)
        ledger.append(question: "O que vê?", answer: "Uma tela.", source: .camera, now: 101)
        check(ledger.turns.count == 1, "button/voice duplicate is not appended twice")
        let observation = ledger.payload(now: 130)[0]
        check(observation["capture_age_seconds"] as? Double == 32 && observation["current_environment_verified"] as? Bool == false, "visual evidence is timestamped history, never live authority")
        check(ledger.payload(now: 401).isEmpty && ledger.payload(now: 99).isEmpty && ledger.payload(now: .nan).isEmpty, "expired/backward/nonfinite context is unavailable")
        ledger.synchronize(owner: "synthetic-owner", revision: "r2")
        check(ledger.turns.isEmpty, "correction/deletion purges conversational echoes")
        for index in 0..<20 { ledger.append(question: "Q\(index)", answer: "A", source: .memory, now: Double(200 + index)) }
        check(ledger.turns.count == 8, "bounded eight completed turns")
        ledger.synchronize(owner: "different-owner", revision: "r2")
        check(ledger.turns.isEmpty, "owner isolation")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = XRPersistentMemory(url: root.appendingPathComponent("memory.json"))
        _ = try store.save(subject: "Luma", statement: "Luma é uma gata que mora comigo e com Nora", correction: false)
        var now = 1000.0
        let base = ConversationFixture()
        var plans = 0
        let runtime = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { now }, pendingState: XRMemoryPendingState(), logicalRecall: { _, _ in
            plans += 1; throw TARSClientError.unavailable
        })
        let before = try store.load()
        let recalled = try await runtime.converse(text: "Quem é a Luma?", language: "pt-BR", context: nil)
        check(recalled.contains("Luma") && base.contexts.isEmpty, "deterministic recall incurs no general call")
        _ = try await runtime.converse(text: "Qual é a capital da França?", language: "pt-BR", context: nil)
        check(plans == 0, "unrelated public question skips the memory planner")
        check(base.dialogue.contains { ($0["answer"] as? String)?.contains("Luma") == true }, "local exchange reaches general conversation despite request epoch change")
        check((base.contexts.last?["xr_memory"] as? [String: Any])?["data_revision"] as? String == before.revision, "data revision is separate from request epoch")
        runtime.recordLocalExchange(question: "Descreva a imagem", answer: "Há uma tela azul.", source: .camera, capturedAt: now - 2)
        _ = try await runtime.converse(text: "Qual a cor dela?", language: "pt-BR", context: nil)
        check(plans == 0, "camera reference does not reenter the prior memory topic")
        _ = try await runtime.converse(text: "O que foi que você viu?", language: "pt-BR", context: nil)
        check(base.dialogue.contains { $0["source"] as? String == "camera" }, "camera-to-general follow-up shares historical result")
        runtime.recordLocalExchange(question: "Leia o email", answer: "Mensagem sintética recebida.", source: .mail, capturedAt: nil)
        _ = try await runtime.converse(text: "Explique essa mensagem", language: "pt-BR", context: nil)
        check(base.dialogue.contains { $0["source"] as? String == "mail" }, "mail-to-general follow-up")
        let afterRead = try store.load()
        check(before.revision == afterRead.revision && before.facts == afterRead.facts, "dialogue has no persistent writes")
        _ = try store.forget(subject: "Luma")
        _ = try await runtime.converse(text: "Quanto é dois mais dois?", language: "pt-BR", context: nil)
        check(base.dialogue.isEmpty, "external deletion purges all stale turns before request")
        now += 301
        _ = try await runtime.converse(text: "Olá", language: "pt-BR", context: nil)
        check(base.dialogue.isEmpty, "retention expires using injected monotonic clock")

        _ = try store.save(subject: "Nora", statement: "Nora mora comigo", correction: false)
        let fresh = MemoryTARSRuntime(underlying: ConversationFixture(), memory: { store }, uptime: { now }, pendingState: XRMemoryPendingState())
        let status = try await fresh.converse(text: "Essa informação está salva no XR?", language: "pt-BR", context: nil)
        check(status.contains("Qual informação"), "nonempty database does not prove an unresolved referent was saved")
        let unavailableBase = ConversationFixture()
        let unavailable = MemoryTARSRuntime(underlying: unavailableBase, memory: { throw XRMemoryError.unavailable }, pendingState: XRMemoryPendingState())
        _ = try await unavailable.converse(text: "Quanto é dois mais dois?", language: "pt-BR", context: nil)
        check(unavailableBase.contexts.count == 1 && unavailableBase.dialogue.isEmpty, "memory failure does not block independent arithmetic or expose old context")
        _ = try await unavailable.converse(text: "Qual o nome da minha mãe?", language: "pt-BR", context: nil)
        check(unavailableBase.contexts.count == 1, "personal memory failures remain fail closed")

        base.paused = true
        let pending = Task { try await runtime.converse(text: "Olá outra vez", language: "pt-BR", context: nil) }
        await waitUntil({ base.wait != nil }, "pending conversation")
        do { _ = try await runtime.converse(text: "Duplicado", language: "pt-BR", context: nil); preconditionFailure("duplicate admitted") }
        catch TARSClientError.ai(let code) { check(code == "AI_BUSY", "single conversation in flight") }
        pending.cancel(); base.wait?.resume(returning: "cancelled answer"); base.wait = nil
        do { _ = try await pending.value; preconditionFailure("cancelled answer delivered") } catch is CancellationError { checks += 1 }
        base.paused = false
        _ = try await runtime.converse(text: "Depois do cancelamento", language: "pt-BR", context: nil)
        check(!base.dialogue.contains { $0["answer"] as? String == "cancelled answer" }, "cancelled output never enters dialogue")

        for text in ["O que você está enxergando?", "Descreva os objetos que você vê", "Você vê um notebook?", "Leia o código na tela", "Procura um gato na imagem"] {
            check(VisualQuestionPolicy.explicitCurrent(text), "explicit vision route: \(text)")
        }
        for text in ["O que você viu?", "Quem é a Luma?", "Leia meu email", "Qual a capital da França?"] {
            check(!VisualQuestionPolicy.explicitCurrent(text), "no paid capture for historical/nonvisual turn")
        }
        check(VisualQuestionPolicy.needsTextDetail("Leia o código na tela") && !VisualQuestionPolicy.needsTextDetail("Descreva o ambiente"), "higher image detail is explicit")
        for phrase in ["TARS escuta", "TARS, pare de falar", "TARS listen", "Uma fala anterior TARS escuta", "Taís escuta"] {
            check(VoiceInterruptionPolicy.matches(phrase), "explicit conversational interruption")
        }
        for phrase in ["pare", "pare a música", "TARS avance", "Ele disse TARS escuta ontem", "TARS"] {
            check(!VoiceInterruptionPolicy.matches(phrase), "ambient speech and body commands never interrupt through this gate")
        }
        check(VoiceInterruptionPolicy.echoes("tars escuta", spoken: "Para me chamar, diga: TARS, escuta."), "echoed command in own output is rejected")
        var fast = VoiceCaptureWindow(now: 10, silenceSeconds: 1.2); fast.observeVoice(now: 11)
        check(fast.decision(now: 12.19) == .keepListening && fast.decision(now: 12.21) == .finish, "bounded faster turn endpoint")
        fast.observeVoice(now: 12.1)
        check(fast.decision(now: 12.5) == .keepListening, "resumed speech preserves utterance")

        let text = String(repeating: "Uma frase de teste com palavras claras. ", count: 15)
        let parts = ConversationPolicy.speechParts(text)
        check(parts.count == 2 && parts.joined() == text, "sentence chunks preserve all words and whitespace")
        check(ConversationPolicy.speechParts("1.2 é um número").count == 1, "short reply remains one paid synthesis")
        var synthesized: [String] = [], played: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let pipeline = Task {
            try await PreparedVoicePipeline.run(text: text, synthesize: { value in
                synthesized.append(value); return Data(value.utf8)
            }, play: { data in
                played.append(String(decoding: data, as: UTF8.self))
                if played.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            })
        }
        await waitUntil({ releaseFirst != nil && synthesized.count == 2 }, "audio prefetch")
        check(played.count == 1 && synthesized.count == 2, "next complete audio prepares during first playback")
        releaseFirst?.resume(); try await pipeline.value
        check(played.joined() == text, "ordered speech exactly once")
        var synthesizedAfterCancellation = 0
        let cancelled = Task {
            try await PreparedVoicePipeline.run(text: text, synthesize: { _ in
                synthesizedAfterCancellation += 1; try Task.checkCancellation(); return Data([1])
            }, play: { _ in preconditionFailure("cancelled audio must not play") })
        }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("cancel accepted") } catch is CancellationError { checks += 1 }
        check(synthesizedAfterCancellation <= 1, "cancelled run does not fan out synthesis")
        var attempts = 0, outputs = 0
        do {
            try await PreparedVoicePipeline.run(text: text, synthesize: { part in
                attempts += 1
                if attempts == 2 { throw TARSClientError.unavailable }
                return Data(part.utf8)
            }, play: { _ in outputs += 1 })
            preconditionFailure("failure hidden")
        } catch { check(outputs == 1 && attempts == 2, "failure after prefix never repeats or switches voices") }
        var prefixDone: CheckedContinuation<Void, Never>?
        var prefetchStarted = false, prefetchCancelled = false
        var cancelOutputs = 0
        let prefetchRun = Task {
            try await PreparedVoicePipeline.run(text: text, synthesize: { part in
                if part == parts[1] {
                    prefetchStarted = true
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { prefetchCancelled = true; throw error }
                }
                return Data(part.utf8)
            }, play: { _ in
                cancelOutputs += 1
                await withCheckedContinuation { prefixDone = $0 }
            })
        }
        await waitUntil({ prefixDone != nil && prefetchStarted }, "cancellable prefetch")
        prefetchRun.cancel(); prefixDone?.resume()
        do { try await prefetchRun.value; preconditionFailure("cancel ignored") } catch is CancellationError { checks += 1 }
        await waitUntil({ prefetchCancelled }, "cancelled upcoming audio")
        check(cancelOutputs == 1, "interrupting playback cancels prefetched remainder")
        var legacyParts = 0
        try await PreparedVoicePipeline.run(text: text, segmented: false, synthesize: { part in
            legacyParts += 1; check(part == text, "legacy full audio preserves text"); return Data([1])
        }, play: { _ in })
        check(legacyParts == 1, "legacy audio switch retains one complete synthesis")
        check(ConversationMemoryQuestion.validName("João Nascimento", relation: "meu pai"), "ordinary surname is not mistaken for a date attribute")
        check(!ConversationMemoryQuestion.validName("aniversário do meu pai", relation: "meu pai"), "a relation attribute label is not a person name")
        var wake = VoiceActivationPolicy()
        check(wake.consume("TARS, wake up") == .acknowledge && wake.awaitingRequest, "name plus wake phrase is a greeting, never a general question")
        check(wake.consume("Wake up, TARS") == .continueListening, "wake phrase plus name is also a greeting")
        check(wake.consume("TARS wake up") == .continueListening, "repeated combined wake does not call general conversation")
        check(ConversationMemoryQuestion.clean("Não, TARS. Eu quero saber quem é a Luma") == "quem é a Luma", "repair address and question wrapper")
        check(ConversationMemoryQuestion.clean("Não quero saber quem é a Luma").hasPrefix("Não"), "negative intent is preserved")
        check(!ConversationMemoryQuestion.maySuggest("Você é um filho da puta. Luma é uma gata"), "incidental abusive transcript is not offered as a fact")
        let readStore = XRPersistentMemory(url: root.appendingPathComponent("read-fixtures.json"))
        _ = try readStore.save(subject: "Luma", statement: "Luma é uma gata que mora comigo e com Nora", correction: false)
        _ = try readStore.save(subject: "Nora", statement: "Nora mora comigo e com Luma", correction: false)
        _ = try readStore.save(subject: "meu irmão", statement: "Caio é meu irmão", correction: false)
        let readBase = ConversationFixture(); var unnecessaryPlans = 0
        let readPending = XRMemoryPendingState()
        let readRuntime = MemoryTARSRuntime(underlying: readBase, memory: { readStore }, uptime: { now }, pendingState: readPending, logicalRecall: { _, _ in
            unnecessaryPlans += 1; return "Pelos fatos registrados: gata."
        })
        let readBefore = try readStore.load()
        let identity = try await readRuntime.converse(text: "Não, TARS. Eu quero saber quem é a Luma", language: "pt-BR", context: nil)
        check(identity.contains("Nora") && identity.contains("gata") && unnecessaryPlans == 0, "full saved identity precedes lossy model interpretation")
        let residence = try await readRuntime.converse(text: "Com quem que ela mora?", language: "pt-BR", context: nil)
        check(residence.contains("Nora") && unnecessaryPlans == 0 && readBase.contexts.isEmpty, "residence follow-up uses only saved evidence without paid interpretation")
        readPending.suggestion = ([("Nova", "Nova é uma gata")], now + 60)
        let brothers = try await readRuntime.converse(text: "Não. Eu quero saber qual o nome dos meus irmãos", language: "pt-BR", context: nil)
        check(readPending.suggestion == nil, "decline plus question never leaves an accidental save pending")
        check(brothers.contains("Caio") && unnecessaryPlans == 0, "repaired sibling question stays deterministic")
        // Model-backed reads must preserve provenance and one named referent,
        // even when several saved facts support the answer.
        let evidenceBase = ConversationFixture()
        let evidenceRuntime = MemoryTARSRuntime(underlying: evidenceBase, memory: { readStore }, uptime: { now }, pendingState: XRMemoryPendingState(), evidenceRecall: { _, document in
            MemoryRecallEvidence(answer: "Resultado sintético baseado nos registros.", sourceKeys: document.facts.filter { ["luma", "nora"].contains($0.key) }.map(\.key), ownerID: document.ownerID, revision: document.revision)
        })
        let evidenceBefore = try Data(contentsOf: root.appendingPathComponent("read-fixtures.json"))
        _ = try await evidenceRuntime.converse(text: "O que sabemos sobre Luma?", language: "pt-BR", context: nil)
        let evidenceFollowUp = try await evidenceRuntime.converse(text: "Com quem que ela mora?", language: "pt-BR", context: nil)
        check(evidenceFollowUp.contains("Nora") && evidenceBase.contexts.isEmpty, "multiple cited sources retain a single named subject")
        let evidenceAfter = try Data(contentsOf: root.appendingPathComponent("read-fixtures.json"))
        check(evidenceAfter == evidenceBefore, "evidence reads leave persistent bytes untouched")
        now += 121
        let expiredFocus = try await evidenceRuntime.converse(text: "Com quem ela mora?", language: "pt-BR", context: nil)
        check(expiredFocus.contains("De quem"), "expired named subject requires clarification")
        _ = try await evidenceRuntime.converse(text: "O que sabemos sobre Luma e Nora?", language: "pt-BR", context: nil)
        let ambiguousFocus = try await evidenceRuntime.converse(text: "Com quem ela mora?", language: "pt-BR", context: nil)
        check(ambiguousFocus.contains("De quem"), "two named subjects never select one pronoun arbitrarily")
        _ = try await evidenceRuntime.converse(text: "O que sabemos sobre Luma?", language: "pt-BR", context: nil)
        evidenceRuntime.recordLocalExchange(question: "Leia o email", answer: "Outra pessoa escreveu.", source: .mail, capturedAt: nil)
        let toolFocus = try await evidenceRuntime.converse(text: "Com quem ela mora?", language: "pt-BR", context: nil)
        check(toolFocus.contains("De quem"), "tool topic clears personal referent")
        let invalidEvidence = MemoryTARSRuntime(underlying: ConversationFixture(), memory: { readStore }, uptime: { now }, pendingState: XRMemoryPendingState(), evidenceRecall: { _, document in
            MemoryRecallEvidence(answer: "Resposta sem fonte válida", sourceKeys: ["invented-source"], ownerID: document.ownerID, revision: document.revision)
        })
        let rejectedEvidence = try await invalidEvidence.converse(text: "O que sabemos sobre Luma?", language: "pt-BR", context: nil)
        check(!rejectedEvidence.contains("Resposta sem fonte"), "runtime rejects nonexistent evidence IDs")
        for mismatch in ["owner", "revision"] {
            let wrongIdentity = MemoryTARSRuntime(underlying: ConversationFixture(), memory: { readStore }, uptime: { now }, pendingState: XRMemoryPendingState(), evidenceRecall: { _, document in
                MemoryRecallEvidence(answer: "Evidência de outra identidade", sourceKeys: ["luma"], ownerID: mismatch == "owner" ? "another-owner" : document.ownerID, revision: mismatch == "revision" ? "another-revision" : document.revision)
            })
            let rejectedIdentity = try await wrongIdentity.converse(text: "O que sabemos sobre Luma?", language: "pt-BR", context: nil)
            check(!rejectedIdentity.contains("Evidência de outra"), "typed evidence rejects " + mismatch + " mismatch")
        }
        let rankedStore = XRPersistentMemory(url: root.appendingPathComponent("ranked-fixtures.json"))
        for name in ["Aline", "Breno", "Caio", "Dora", "Estela"] {
            _ = try rankedStore.save(subject: name, statement: name + " participa do grupo", correction: false)
        }
        let rankedDocument = try rankedStore.load()
        let ranked = rankedStore.context(for: "O que sabemos sobre Estela?", document: rankedDocument, followUpKeys: rankedDocument.facts.map(\.key))
        let selected = ranked["facts"] as? [[String: Any]] ?? []
        check(selected.first?["subject"] as? String == "Estela" && selected.count == 4, "explicit subject outranks four old follow-up keys")
        check(ranked["matched_fact_count"] as? Int == 5 && ranked["omitted_fact_count"] as? Int == 1, "bounded retrieval reports omitted evidence")
        let revisionStore = XRPersistentMemory(url: root.appendingPathComponent("revision-fixtures.json"))
        _ = try revisionStore.save(subject: "Iara", statement: "Iara mora comigo e com Raul", correction: false)
        let revisionRuntime = MemoryTARSRuntime(underlying: ConversationFixture(), memory: { revisionStore }, uptime: { now }, pendingState: XRMemoryPendingState())
        _ = try await revisionRuntime.converse(text: "Quem é Iara?", language: "pt-BR", context: nil)
        _ = try revisionStore.forget(subject: "Iara")
        let deletedReferent = try await revisionRuntime.converse(text: "Com quem ela mora?", language: "pt-BR", context: nil)
        check(deletedReferent.contains("De quem") && !deletedReferent.contains("Raul"), "external deletion invalidates referent and its evidence")
        let readAfter = try readStore.load()
        check(readAfter.revision == readBefore.revision && readAfter.facts == readBefore.facts, "physical-transcript read sequence never changes persistent facts")
        let choicesStore = XRPersistentMemory(url: root.appendingPathComponent("choice-fixtures.json"))
        _ = try choicesStore.save(subject: "Nilo", statement: "Nilo é meu pai", correction: false)
        _ = try choicesStore.save(subject: "Renato", statement: "Renato é meu pai", correction: false)
        _ = try choicesStore.save(subject: "meu pai nascimento", statement: "Meu pai nasceu em 6 de setembro de 1940", correction: false)
        let choicesBase = ConversationFixture(); let choicePending = XRMemoryPendingState()
        let choicesRuntime = MemoryTARSRuntime(underlying: choicesBase, memory: { choicesStore }, uptime: { now }, pendingState: choicePending)
        let choiceBefore = try choicesStore.load()
        let options = try await choicesRuntime.converse(text: "E o nome do meu pai?", language: "pt-BR", context: nil)
        check(options.contains("Nilo") && options.contains("Renato") && !options.contains("1940") && !options.contains("nascimento"), "only supported names become choices, not attribute labels")
        let choice = try await choicesRuntime.converse(text: "B", language: "pt-BR", context: nil)
        check(choice.contains("Renato") && choicesBase.contexts.isEmpty, "B resolves the active choice locally")
        let choiceAfter = try choicesStore.load()
        check(choiceAfter.revision == choiceBefore.revision, "choosing B is not an implicit memory correction")
        _ = try await choicesRuntime.converse(text: "Qual o nome do meu pai?", language: "pt-BR", context: nil)
        now += 121
        let expired = try await choicesRuntime.converse(text: "B", language: "pt-BR", context: nil)
        check(expired.contains("expirou"), "expired choice cannot become a fact or arbitrary model acknowledgement")
        let nameStore = XRPersistentMemory(url: root.appendingPathComponent("name-label-fixtures.json"))
        for (subject, statement) in [("Elias", "Elias é meu pai"),
            ("aniversário do meu pai", "Meu pai nasceu em 6 de setembro de 1940"),
            ("meu pai nascimento", "Meu pai nasceu em 6 de setembro de 1940"),
            ("meu pai nascimento nascimento", "Meu pai nasceu em 6 de setembro de 1940")] {
            _ = try nameStore.save(subject: subject, statement: statement, correction: false)
        }
        let nameRuntime = MemoryTARSRuntime(underlying: ConversationFixture(), memory: { nameStore }, pendingState: XRMemoryPendingState())
        let nameAnswer = try await nameRuntime.converse(text: "E o nome do meu pai?", language: "pt-BR", context: nil)
        check(nameAnswer.contains("Elias") && !nameAnswer.contains("possibilidade") && !nameAnswer.contains("nascimento"), "legacy date slots do not become alternative parent names")
        var echo = VoiceEchoPolicy(); echo.lastOutput = "A imagem mostra uma tela. Há manchas visíveis na superfície da tela."; echo.endedAt = 100
        check(echo.isEcho("Há manchas visíveis na superfície da tela", captureStarted: 100.2), "recent literal spoken tail is suppressed")
        check(!echo.isEcho("TARS, há manchas visíveis na superfície da tela", captureStarted: 100.2), "explicitly addressed repetition is intentional input")
        check(!echo.isEcho("Não", captureStarted: 100.2) && !echo.isEcho("Qual o nome dos meus irmãos?", captureStarted: 100.2), "short replies and new questions are never echo-filtered")
        check(!echo.isEcho("Há manchas visíveis na superfície da tela", captureStarted: 105), "echo window expires")
        print("PASS: \(checks) conversation, provenance, retention, cancellation, routing and prepared-voice pipeline checks; simulated inputs only, no API/hardware")
    }
}
