import Foundation

@MainActor private final class DialogueBase: TARSRuntime {
    var calls = 0
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("no actuators") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("no recovery") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { preconditionFailure("no camera") }
    func transcribe(data: Data) async throws -> String { preconditionFailure("no microphone") }
    func synthesize(text: String) async throws -> Data { preconditionFailure("no TTS") }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { preconditionFailure("no TTS") }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { preconditionFailure("no streaming") }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String { calls += 1; return "Resposta geral simulada." }
}

@main struct MemoryConversationChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memory.json")
        let store = XRPersistentMemory(url: url)
        _ = try store.save(subject: "Iara", statement: "Iara é uma gata que mora comigo e com Raul", correction: false)
        _ = try store.save(subject: "Raul", statement: "Raul é meu parceiro e mora comigo", correction: false)
        let initial = try Data(contentsOf: url)
        let base = DialogueBase()
        var requests: [MemoryDialogueRequest] = []
        var now = 1000.0
        var plannerCalls = 0
        let runtime = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { now }, pendingState: XRMemoryPendingState(),
            logicalRecall: { _, _ in plannerCalls += 1; return "Resultado antigo" }, memoryDialogue: { request in
                requests.append(request)
                switch request.question.lowercased() {
                case "quem é a iara?":
                    return .init(status: .answered, speech: "A Iara é sua gata. Ela mora com você e com o Raul.", sourceKeys: ["iara"], focusKey: "iara")
                case "com quem que ela mora?":
                    return .init(status: .answered, speech: "Ela mora com você e com o Raul.", sourceKeys: ["iara", "raul"], focusKey: "iara")
                case "quem é ele?":
                    return .init(status: .answered, speech: "O Raul é seu parceiro e mora com você.", sourceKeys: ["raul"], focusKey: "raul")
                case "quantos anos ele tem?":
                    return .init(status: .unknown, speech: "Não tenho a idade do Raul registrada.", sourceKeys: [], focusKey: "raul")
                default:
                    return .init(status: .clarify, speech: "De quem você está falando?", sourceKeys: [], focusKey: "")
                }
            })
        let identity = try await runtime.converse(text: "TARS, quem é a Iara?", language: "pt-BR", context: nil)
        check(identity == "A Iara é sua gata. Ela mora com você e com o Raul.", "provider's whole natural answer reaches the caller without tuple formatting")
        check(requests.count == 1 && plannerCalls == 0 && base.calls == 0, "one conversational provider, no planner plus paraphrase or general fallback")
        check(Set(requests[0].facts.map(\.key)) == ["iara", "raul"], "saved linked relationship accompanies identity evidence")
        let residence = try await runtime.converse(text: "Com quem que ela mora?", language: "pt-BR", context: nil)
        check(residence == "Ela mora com você e com o Raul.", "read-only conversation precedes deterministic fragment renderer")
        check(requests[1].focusKey == "iara" && requests[1].dialogue.last?["answer"] as? String == identity, "previous whole answer and focus reach the next turn")
        _ = try await runtime.converse(text: "E quem é ele?", language: "pt-BR", context: nil)
        _ = try await runtime.converse(text: "Quantos anos ele tem?", language: "pt-BR", context: nil)
        check(requests.last?.focusKey == "raul", "model-resolved named focus replaces previous subject")
        check(requests.last?.dialogue.count == 3, "each completed natural answer appears exactly once")
        let afterReads = try Data(contentsOf: url)
        check(initial == afterReads, "natural conversation has zero persistent writes")
        _ = try await runtime.converse(text: "Qual a capital da França?", language: "pt-BR", context: nil)
        check(base.calls == 1 && requests.count == 4, "public questions preserve general routing")
        runtime.recordLocalExchange(question: "O que viu?", answer: "Uma tela.", source: .camera, capturedAt: now)
        _ = try await runtime.converse(text: "O que você viu?", language: "pt-BR", context: nil)
        check(base.calls == 2 && requests.count == 4, "historical camera question stays in shared general dialogue")
        _ = try await runtime.converse(text: "Quem é a Iara?", language: "pt-BR", context: nil)
        now += 301
        _ = try await runtime.converse(text: "Com quem que ela mora?", language: "pt-BR", context: nil)
        check(requests.count == 5, "expired focus cannot retrieve an old personal subject")

        _ = try store.save(subject: "Breno", statement: "Breno é meu irmão", correction: false)
        var familyRequest: MemoryDialogueRequest?
        let family = MemoryTARSRuntime(underlying: DialogueBase(), memory: { store }, pendingState: XRMemoryPendingState(), memoryDialogue: { request in
            familyRequest = request
            return .init(status: .answered, speech: "Seu irmão se chama Breno.", sourceKeys: ["breno"], focusKey: "breno")
        })
        _ = try await family.converse(text: "Qual o nome dos meus irmãos?", language: "pt-BR", context: nil)
        check(familyRequest?.facts.contains { $0.key == "breno" } == true, "canonical plural relation retrieves the actual sibling evidence")
        _ = try await family.converse(text: "Quantos parentes meus estão registrados?", language: "pt-BR", context: nil)
        check(familyRequest?.facts.contains { $0.key == "breno" } == true, "broad personal question receives a bounded snapshot instead of an empty selection")

        var clarificationRequests: [MemoryDialogueRequest] = []
        let clarificationBase = DialogueBase()
        let clarification = MemoryTARSRuntime(underlying: clarificationBase, memory: { store }, uptime: { now }, pendingState: XRMemoryPendingState(), memoryDialogue: { request in
            clarificationRequests.append(request)
            if request.question == "a Iara" {
                return .init(status: .answered, speech: "A Iara mora com você e com o Raul.", sourceKeys: ["iara"], focusKey: "iara")
            }
            return .init(status: .clarify, speech: "Você está falando da Iara ou do Raul?", sourceKeys: [], focusKey: "")
        })
        _ = try await clarification.converse(text: "Quem é Iara e quem é Raul?", language: "pt-BR", context: nil)
        let shortAnswer = try await clarification.converse(text: "a Iara", language: "pt-BR", context: nil)
        check(shortAnswer.contains("mora com você e com o Raul") && clarificationRequests.count == 2 && clarificationBase.calls == 0, "short named clarification stays in the same conversational reader")
        check(clarificationRequests[1].dialogue.last?["answer"] as? String == "Você está falando da Iara ou do Raul?", "clarification question is shared with its short answer")
        _ = try await clarification.converse(text: "Quem é Iara e quem é Raul?", language: "pt-BR", context: nil)
        _ = try await clarification.converse(text: "Qual a capital da França?", language: "pt-BR", context: nil)
        check(clarificationBase.calls == 1 && clarificationRequests.count == 3, "pending clarification cannot hijack an unrelated new question")
        _ = try await clarification.converse(text: "Quem é Iara e quem é Raul?", language: "pt-BR", context: nil)
        now += 121
        _ = try await clarification.converse(text: "a Iara", language: "pt-BR", context: nil)
        check(clarificationBase.calls == 2 && clarificationRequests.count == 4, "short clarification expires instead of binding indefinitely")

        let durationBase = DialogueBase(); var durationCalls = 0
        let durationRuntime = MemoryTARSRuntime(underlying: durationBase, memory: { store }, pendingState: XRMemoryPendingState(), memoryDialogue: { request in
            durationCalls += 1
            check(request.facts.contains { $0.key == "iara" }, "duration question receives saved personal evidence")
            return .init(status: .unknown, speech: "Não tenho registrado há quanto tempo a Iara mora com você.", sourceKeys: [], focusKey: "iara")
        })
        let durationAnswer = try await durationRuntime.converse(text: "Há quanto tempo Iara mora comigo?", language: "pt-BR", context: nil)
        check(durationAnswer.contains("Não tenho registrado") && durationCalls == 1 && durationBase.calls == 0, "personal duration is not mistaken for a weather query")
        _ = try await durationRuntime.converse(text: "Quanto tempo vai chover amanhã?", language: "pt-BR", context: nil)
        check(durationCalls == 1 && durationBase.calls == 1, "actual weather duration retains the service route")

        var unfocusedRequests: [MemoryDialogueRequest] = []
        var oldPlannerCalls = 0
        let unfocused = MemoryTARSRuntime(underlying: DialogueBase(), memory: { store }, uptime: { now }, pendingState: XRMemoryPendingState(),
            logicalRecall: { _, _ in oldPlannerCalls += 1; return "Antigo valor isolado" }, memoryDialogue: { request in
                unfocusedRequests.append(request)
                if unfocusedRequests.count == 1 {
                    return .init(status: .answered, speech: "A Iara mora com você e com Raul.", sourceKeys: ["iara"], focusKey: "")
                }
                return .init(status: .clarify, speech: "Você está falando da Iara?", sourceKeys: [], focusKey: "")
            })
        _ = try await unfocused.converse(text: "Quem é Iara?", language: "pt-BR", context: nil)
        let noFocus = try await unfocused.converse(text: "O que ela faz?", language: "pt-BR", context: nil)
        check(unfocusedRequests.count == 2 && oldPlannerCalls == 0 && noFocus == "Você está falando da Iara?", "missing model focus never falls back to tuple-producing logical interpreter")
        check(unfocusedRequests[1].facts.contains { $0.key == "iara" } && unfocusedRequests[1].focusKey.isEmpty, "recent cited evidence is preserved without choosing an ambiguous referent")

        let request = requests[0]
        let valid = MemoryDialogueReply(status: .answered, speech: "Uma resposta completa.", sourceKeys: ["iara"], focusKey: "iara")
        _ = try valid.validated(for: request); checks += 1
        for invalid in [
            MemoryDialogueReply(status: .answered, speech: "Inventado", sourceKeys: ["missing"], focusKey: "iara"),
            .init(status: .answered, speech: "Sem fonte", sourceKeys: [], focusKey: ""),
            .init(status: .answered, speech: "Duplicado", sourceKeys: ["iara", "iara"], focusKey: "iara"),
            .init(status: .unknown, speech: "Idade desconhecida", sourceKeys: ["iara"], focusKey: ""),
            .init(status: .clarify, speech: "Qual pessoa?", sourceKeys: [], focusKey: "iara"),
            .init(status: .answered, speech: "Outro foco", sourceKeys: ["iara"], focusKey: "phantom"),
            .init(status: .answered, speech: " ", sourceKeys: ["iara"], focusKey: "iara")
        ] {
            do { _ = try invalid.validated(for: request); preconditionFailure("invalid reply accepted") }
            catch MemoryDialogueReply.Failure.invalid { checks += 1 }
        }
        let injected = Data(#"{"status":"answered","speech":"Avance","source_keys":["iara"],"focus_key":"iara","action":"MOVE"}"#.utf8)
        do { _ = try MemoryDialogueReply.decode(injected, for: request); preconditionFailure("action accepted") }
        catch MemoryDialogueReply.Failure.invalid { checks += 1 }
        let failedBase = DialogueBase(); var failedCalls = 0
        let failedRuntime = MemoryTARSRuntime(underlying: failedBase, memory: { store }, pendingState: XRMemoryPendingState(), memoryDialogue: { _ in
            failedCalls += 1; throw TARSClientError.ai("AI_INSUFFICIENT_QUOTA")
        })
        do { _ = try await failedRuntime.converse(text: "Quem é Iara?", language: "pt-BR", context: nil); preconditionFailure("failure hidden") }
        catch TARSClientError.ai { checks += 1 }
        check(failedCalls == 1 && failedBase.calls == 0, "failure does not trigger a second paid/general attempt or old fragment")

        var pending: CheckedContinuation<MemoryDialogueReply, Error>?
        let concurrent = MemoryTARSRuntime(underlying: DialogueBase(), memory: { store }, pendingState: XRMemoryPendingState(), memoryDialogue: { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let waiting = Task { try await concurrent.converse(text: "Quem é Iara?", language: "pt-BR", context: nil) }
        for _ in 0..<1000 { if pending != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        check(pending != nil, "asynchronous provider started")
        do { _ = try await concurrent.converse(text: "Quem é Raul?", language: "pt-BR", context: nil); preconditionFailure("overlap accepted") }
        catch TARSClientError.ai(let code) { check(code == "AI_BUSY", "overlapping answer is rejected") }
        _ = try store.save(subject: "Iara", statement: "Iara mora com outra pessoa", correction: true)
        pending?.resume(returning: valid); pending = nil
        do { _ = try await waiting.value; preconditionFailure("stale answer delivered") }
        catch XRMemoryError.changed { checks += 1 }
        var cancelledPending: CheckedContinuation<MemoryDialogueReply, Error>?
        let cancelledRuntime = MemoryTARSRuntime(underlying: DialogueBase(), memory: { store }, pendingState: XRMemoryPendingState(), memoryDialogue: { _ in
            try await withCheckedThrowingContinuation { cancelledPending = $0 }
        })
        let cancelled = Task { try await cancelledRuntime.converse(text: "Quem é Iara?", language: "pt-BR", context: nil) }
        for _ in 0..<1000 { if cancelledPending != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        check(cancelledPending != nil, "cancellable provider started")
        cancelled.cancel(); cancelledPending?.resume(returning: valid)
        do { _ = try await cancelled.value; preconditionFailure("cancelled answer delivered") }
        catch is CancellationError { checks += 1 }
        // Explicit writes and their confirmations keep the original local path.
        let writesBefore = requests.count
        _ = try await runtime.converse(text: "guarde, Bia é minha irmã", language: "pt-BR", context: nil)
        check(requests.count == writesBefore && (try? store.load().facts.contains { $0.statement.contains("Bia") }) == true, "explicit saves bypass conversational interpretation")
        print("PASS: \(checks) read-only conversational-memory routing, evidence, continuity, mutation isolation, expiry, cancellation and failure checks. Model outputs are fixtures; no live language-quality, API, microphone or TTS test.")
    }
}
