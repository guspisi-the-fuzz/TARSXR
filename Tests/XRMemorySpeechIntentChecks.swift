import Foundation

@MainActor
private final class SpeechIntentFixtureRuntime: TARSRuntime {
    private(set) var conversationCalls = 0
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { throw TARSClientError.rejected("STOP") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { throw TARSClientError.rejected("STOP") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { throw TARSClientError.unavailable }
    func synthesize(text: String) async throws -> Data { throw TARSClientError.unavailable }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        conversationCalls += 1
        return "fixture response"
    }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
}

@main
struct XRMemorySpeechIntentChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); checks += 1 }
        let save: XRMemoryIntent = .save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
        let positive = [
            "Guarde que a Mel é minha gata.",
            "Guarda que a Mel é minha gata.",
            "Por favor, guarde que a Mel é minha gata.",
            "Por favor guarda que a Mel é minha gata",
            "Guarde na memória que a Mel é minha gata.",
            "Guarda na sua memória: a Mel é minha gata.",
            "Salve na memória que a Mel é minha gata.",
            "Salva que a Mel é minha gata.",
            "Anota que a Mel é minha gata.",
            "Memorize que a Mel é minha gata.",
            "Pode guardar que a Mel é minha gata?",
            "Você pode salvar que a Mel é minha gata?",
            "Por favor, poderia anotar que a Mel é minha gata?",
            "Você poderia memorizar a Mel é minha gata.",
            "Guarde que a Mel é minha gata, por favor.",
            "\n  Guarde\tque a Mel é minha gata.  ",
            "Guarda\u{00A0}que\u{00A0}a Mel é minha gata.",
            "Guarde que a Mel e\u{301} minha gata.",
        ]
        for text in positive { check(XRMemoryIntent.parse(text) == save, "explicit request: \(text)") }
        check(XRMemoryIntent.parse("Please, remember that Mel is my cat.") == .save(subject: "Mel", statement: "Mel is my cat", correction: false), "English polite save")
        check(XRMemoryIntent.parse("Please save in your memory that Mel is my cat, please.") == .save(subject: "Mel", statement: "Mel is my cat", correction: false), "English memory target")
        check(XRMemoryIntent.parse("Você pode corrigir que a Mel é minha cachorra?") == .save(subject: "a Mel", statement: "a Mel é minha cachorra", correction: true), "explicit correction still required")
        check(XRMemoryIntent.english("Please, remember Mel is my cat"), "English local acknowledgement")
        check(!XRMemoryIntent.english("Por favor, guarde que a Mel é minha gata"), "Portuguese local acknowledgement")

        for text in ["Você lembra quem é a Mel?", "Voce se lembra de quem é a Mel?", "Lembra quem é a Mel?", "Por favor, você lembra quem é a Mel?"] {
            check(XRMemoryIntent.parse(text) == .recall("a Mel", explicit: true), "explicit recall: \(text)")
        }
        for text in ["Quem é a Mel?", "Por favor, quem é a Mel?", "Quem\t e\u{301} a Mel?"] {
            check(XRMemoryIntent.parse(text) == .recall("a Mel", explicit: false), "recall: \(text)")
        }
        let nonCommands = [
            "A Mel é minha gata.", "Não guarde que a Mel é minha gata.",
            "Não guarda que a Mel é minha gata.", "Por favor, não guarde que a Mel é minha gata.",
            "Eu disse guarde que a Mel é minha gata.", "Ele pediu para guardar que a Mel é minha gata.",
            "Diga guarde que a Mel é minha gata.", "Explique a frase guarde que a Mel é minha gata.",
            "\"Guarde que a Mel é minha gata.\"", "Lembro que a Mel é minha gata.",
            "Você lembra que a Mel é minha gata?", "Can you explain the phrase save Mel is my cat?",
            "Do not save Mel is my cat.", "O guarda é um policial.",
            "A instrução é: por favor, guarde que a Mel é minha gata.",
        ]
        for text in nonCommands { check(XRMemoryIntent.parse(text) == .ordinary, "no implicit save: \(text)") }
        for text in ["Guarda", "Pode guardar?", "Por favor, guarde", "Guarda na memória", "Guarde que ela é minha gata", "Guarda que TARS é independente do Mac", "Por favor, guarda que senha é segredo", "Guarde que a memória: Mel é gata", "Guarde que a Mel e minha gata"] {
            check(XRMemoryIntent.parse(text) == .help, "missing or unsupported fact fails closed: \(text)")
        }
        check(XRMemoryIntent.parse(String(repeating: "x", count: 4097)) == .help, "input bound")
        check(XRMemoryIntent.parse("Guarde que " + String(repeating: "x", count: 81) + " é um sujeito") == .help, "subject bound")
        check(XRMemoryIntent.parse("Guarde que a Mel é " + String(repeating: "x", count: 500)) == .help, "statement bound")

        for question in ["Que dia é meu aniversário", "Que dia é o meu aniversário?", "Que data é meu aniversário", "TARS, por favor, que dia é meu aniversário"] {
            check(XRMemoryIntent.isQuestionLike(question), "birthday stays a question")
            check(XRMemoryIntent.parse(question) == .recall("meu aniversário", explicit: true), "birthday recalled locally")
            check(XRMemoryIntent.suggestedFact(question) == nil, "question never offered as a fact")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-memory-intent-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, text) in positive.enumerated() {
            let path = root.appendingPathComponent("case-\(index)/memory-v1.json")
            let base = SpeechIntentFixtureRuntime()
            let store = XRPersistentMemory(url: path)
            let runtime = MemoryTARSRuntime(underlying: base, memory: { store })
            var wake = VoiceActivationPolicy()
            _ = wake.consume("TARS")
            guard case .request(let routed) = wake.consume(text) else { preconditionFailure("wake lost memory request") }
            let reply = try await runtime.converse(text: routed, language: "pt-BR", context: nil)
            check(reply == "Salvei neste XR: a Mel é minha gata.", "acknowledgement after verified save")
            check(base.conversationCalls == 0, "save did not reach remote conversation")
            check(FileManager.default.fileExists(atPath: path.path), "real file created")
            let loaded = try XRPersistentMemory(url: path).load()
            check(loaded.facts.count == 1 && loaded.facts[0].key == "mel", "correct fact key (not 'na memoria que a mel')")
            check(loaded.facts[0].statement == "a Mel é minha gata", "statement preserved")
            let next = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: path) })
            let recall = try await next.converse(text: "Você lembra quem é a Mel?", language: "pt-BR", context: nil)
            check(recall == "A Mel é sua gata.", "fresh runtime loads durable fact")
            check(base.conversationCalls == 0, "recall local")
        }
        let noSavePath = root.appendingPathComponent("no-implicit/memory-v1.json")
        let noSaveBase = SpeechIntentFixtureRuntime()
        let noSave = MemoryTARSRuntime(underlying: noSaveBase, memory: { XRPersistentMemory(url: noSavePath) })
        for text in nonCommands {
            _ = try await noSave.converse(text: text, language: "pt-BR", context: nil)
            check(!FileManager.default.fileExists(atPath: noSavePath.path), "reported/negated speech never writes memory")
        }
        let failureBase = SpeechIntentFixtureRuntime()
        let failure = MemoryTARSRuntime(underlying: failureBase, memory: {
            XRPersistentMemory(url: root.appendingPathComponent("unwritable/memory-v1.json"), writer: { _, _ in throw XRMemoryError.unavailable })
        })
        let failReply = try await failure.converse(text: "Por favor, guarda que a Mel é minha gata.", language: "pt-BR", context: nil)
        check(!failReply.contains("Salvei"), "failed disk write not acknowledged as saved")
        check(failureBase.conversationCalls == 0, "failure not delegated to LLM to invent saved acknowledgement")
        print("PASS: \(checks) memory speech-intent checks; explicit commands, real temporary files, no ASR or device")
    }
}
