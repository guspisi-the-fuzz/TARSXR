import Foundation

@MainActor
private final class Status26FixtureRuntime: TARSRuntime {
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
struct XRMemoryStatus26Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-memory-status26-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("only-residents-status.json")
            let base = Status26FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 25000.0 })
            let saved = try await rt.converse(text: "Eu tenho essa informação e estou dizendo, moram comigo apenas Mel e Daniela. Salva essas informações no XR.", language: "pt-BR", context: nil)
            check(saved.contains("Salvei neste XR"), "only-residents save remained local")
            let home = try await rt.converse(text: "Quem mora comigo?", language: "pt-BR", context: nil)
            check(home.contains("Mel") && home.contains("Daniela"), "only-residents recall still works")
            let besides = try await rt.converse(text: "Além da Daniela, quem mora comigo?", language: "pt-BR", context: nil)
            check(besides.contains("Mel") && !besides.contains("Daniela e"), "only-residents exclusion still works")
            _ = try await rt.converse(text: "Daniela e Dani são a mesma pessoa?", language: "pt-BR", context: nil)
            let status = try await rt.converse(text: "Essa informação está salva no XR ou só nessa conversa?", language: "pt-BR", context: nil)
            check(status.contains("memória local") && status.contains("XR"), "memory status answered locally")
            check(!status.contains("REMOTE"), "memory status did not call remote")
            check(base.calls == 0, "status scenario stayed local")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("seeded-status.json")
            let store = XRPersistentMemory(url: url)
            _ = try store.save(subject: "Mel", statement: "A Mel é uma gata que mora com você e com a Daniela", correction: false)
            _ = try store.save(subject: "Dani", statement: "Dani mora comigo", correction: false)
            let base = Status26FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 25100.0 })
            let daniela = try await rt.converse(text: "Quem é a Daniela?", language: "pt-BR", context: nil)
            check(daniela.contains("Daniela") && daniela.contains("Mel"), "seeded co-resident recall still works")
            let status = try await rt.converse(text: "Essa informação está salva no XR ou só nessa conversa?", language: "pt-BR", context: nil)
            check(status.contains("memória local") && status.contains("XR"), "seeded status answered locally")
            check(base.calls == 0, "seeded status stayed local")
        }

        do {
            XRMemoryPendingState.shared.clear()
            let url = root.appendingPathComponent("empty-status.json")
            let base = Status26FixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: url) }, uptime: { 25200.0 })
            let status = try await rt.converse(text: "Essa informação está salva no XR ou só nessa conversa?", language: "pt-BR", context: nil)
            check(status.contains("Não encontrei") && status.contains("XR"), "empty status answered locally")
            check(base.calls == 0, "empty status did not call remote")
        }

        print("PASS: \(checks) XR memory status checks")
    }
}
