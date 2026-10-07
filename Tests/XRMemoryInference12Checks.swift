import Foundation

@MainActor
private final class Inference12FixtureRuntime: TARSRuntime {
    var calls = 0
    var contexts: [[String:Any]] = []
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("no motion") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("no recover") }
    func describeImage(png: Data, source: String, question: String, history: [[String:String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { throw TARSClientError.unavailable }
    func synthesize(text: String) async throws -> Data { Data() }
    func converse(text: String, language: String, context: [String:Any]?) async throws -> String { calls += 1; contexts.append(context ?? [:]); return "REMOTE" }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
    var selected: [[String: Any]] { (contexts.last?["xr_memory"] as? [String: Any])?["facts"] as? [[String: Any]] ?? [] }
}

@main
struct XRMemoryInference12Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func containsStandaloneDani(_ text: String) -> Bool {
            let pattern = #"(?i)(^|[^\p{L}])dani([^\p{L}]|$)"#
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return (try? NSRegularExpression(pattern: pattern, options: [])).flatMap { regex in
                regex.firstMatch(in: text, options: [], range: range)
            } != nil
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-memory-inference12-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("coresidents.json")
            let store = XRPersistentMemory(url: url)
            _ = try store.save(subject: "Mel", statement: "A Mel é uma gata que mora com você e com a Daniela", correction: false)
            _ = try store.save(subject: "Dani", statement: "Dani mora comigo", correction: false)
            let base = Inference12FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 12000.0 })
            let daniela = try await rt.converse(text: "Quem é a Daniela?", language: "pt-BR", context: nil)
            check(daniela.contains("Daniela"), "Daniela named from concrete memory")
            check(daniela.localizedCaseInsensitiveContains("mora com você"), "Daniela inferred as co-resident")
            check(daniela.contains("Mel"), "Mel linked to Daniela")
            check(!containsStandaloneDani(daniela), "Dani alias not duplicated in Daniela answer")
            let home = try await rt.converse(text: "Quem mora comigo?", language: "pt-BR", context: nil)
            check(home.contains("Mel"), "Mel listed as co-resident")
            check(home.contains("Daniela"), "Daniela listed as co-resident")
            check(!containsStandaloneDani(home), "Dani alias collapsed in household list")
            let besides = try await rt.converse(text: "Além da Daniela, quem mora comigo?", language: "pt-BR", context: nil)
            check(besides.contains("Mel"), "besides Daniela returns Mel")
            check(!containsStandaloneDani(besides), "besides Daniela does not leak Dani alias")
            check(!besides.contains("Daniela e"), "besides Daniela excludes Daniela from list")
            let alias = try await rt.converse(text: "Daniela e Dani são a mesma pessoa?", language: "pt-BR", context: nil)
            check(alias.contains("Dani") && alias.contains("Daniela"), "alias question handled locally")
            check(base.calls == 0, "concrete co-resident inference stayed local")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("direct-recall-followup.json")
            let store = XRPersistentMemory(url: url)
            _ = try store.save(subject: "Mel", statement: "Mel é uma gata que mora comigo e com a Daniela", correction: false)
            let base = Inference12FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 12100.0 })
            let mel = try await rt.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
            check(mel.localizedCaseInsensitiveContains("Mel"), "direct Mel recall remains local")
            _ = try await rt.converse(text: "Fale mais.", language: "pt-BR", context: nil)
            check(base.selected.count == 1 && base.selected[0]["key"] as? String == "mel", "develop follow-up keeps last recalled Mel record")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("hypothesis.json")
            let store = XRPersistentMemory(url: url)
            _ = try store.save(subject: "Mel", statement: "A Mel é uma gata que mora com você e com a Daniela", correction: false)
            let base = Inference12FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 12200.0 })
            let answer = try await rt.converse(text: "Se a Mel é uma gata que mora comigo e com a Daniela, logo...", language: "pt-BR", context: nil)
            check(!answer.contains("Quer que eu guarde"), "hypothesis is not offered as memory")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("only-residents.json")
            let base = Inference12FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 13000.0 })
            let immediate = try await rt.converse(text: "Eu tenho essa informação e estou dizendo, moram comigo apenas Mel e Daniela. Salva essas informações no XR.", language: "pt-BR", context: nil)
            check(immediate.contains("Salvei neste XR"), "same-turn only-residents save stays local")
            let home = try await rt.converse(text: "Quem mora comigo?", language: "pt-BR", context: nil)
            check(home.contains("Mel") && home.contains("Daniela"), "only-residents fact recalled")
            check(!containsStandaloneDani(home), "only-residents fact suppresses stale alias")
            let besides = try await rt.converse(text: "Além da Daniela, quem mora comigo?", language: "pt-BR", context: nil)
            check(besides.contains("Mel") && !besides.contains("Daniela e"), "only-residents exclusion works after save")
            check(base.calls == 0, "only-residents same-turn flow stayed local")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("only-residents-confirm.json")
            let base = Inference12FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 13100.0 })
            let suggestion = try await rt.converse(text: "Eu tenho essa informação e estou dizendo, moram comigo apenas Mel e Daniela.", language: "pt-BR", context: nil)
            check(suggestion.contains("Quer que eu guarde"), "only-residents statement becomes local suggestion")
            let saved = try await rt.converse(text: "Salva essas informações no XR.", language: "pt-BR", context: nil)
            check(saved.contains("Salvei neste XR"), "plural deictic save confirms suggestion")
        }

        print("PASS: \(checks) concrete memory inference checks")
    }
}

