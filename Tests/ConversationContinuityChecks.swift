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
        print("PASS: \(checks) conversation, provenance, retention, cancellation, routing and prepared-voice pipeline checks; simulated inputs only, no API/hardware")
    }
}
