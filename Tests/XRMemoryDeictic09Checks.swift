import Foundation

@MainActor
private final class DeicticFixtureRuntime: TARSRuntime {
    var calls = 0
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("no motion") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("no recover") }
    func describeImage(png: Data, source: String, question: String, history: [[String:String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { throw TARSClientError.unavailable }
    func synthesize(text: String) async throws -> Data { Data() }
    func converse(text: String, language: String, context: [String:Any]?) async throws -> String { calls += 1; return "REMOTE" }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
}

@main
struct XRMemoryDeictic09Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-memory-deictic09-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = XRPersistentMemory(url: root.appendingPathComponent("father.json"))
            let state = XRMemoryPendingState()
            let base = DeicticFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { 2000.0 }, pendingState: state)

            let suggested = try await rt.converse(text: "O nome do meu pai é Orlando Pise e o aniversário dele é 6 de setembro de 1940", language: "pt-BR", context: nil)
            check(suggested.contains("Quer que eu guarde"), "combined father name and birthday becomes local suggestion")
            check(base.calls == 0, "combined statement did not reach model")
            check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("father.json").path), "combined suggestion not written before confirmation")

            let saved = try await rt.converse(text: "Guarda essa informação pra mim, por gentileza?", language: "pt-BR", context: nil)
            check(saved.contains("Salvei neste XR"), "deictic save confirms pending suggestion")
            check(base.calls == 0, "deictic save did not reach model")
            let doc = try store.load()
            check(doc.facts.count == 2, "identity plus birthday persisted")

            let recalled = try await rt.converse(text: "Qual é a data de nascimento do meu pai?", language: "pt-BR", context: nil)
            check(recalled.contains("Orlando Pise"), "father name retained after deictic save")
            check(recalled.contains("6 de setembro de 1940"), "father birthday recalled after deictic save")
        }

        do {
            let store = XRPersistentMemory(url: root.appendingPathComponent("siblings.json"))
            let state = XRMemoryPendingState()
            let base = DeicticFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { 3000.0 }, pendingState: state)

            let suggested = try await rt.converse(text: "O nome dos meus irmãos são Guilherme e Orlando Pise Júnior", language: "pt-BR", context: nil)
            check(suggested.contains("Quer que eu guarde"), "sibling names become local suggestion")
            check(base.calls == 0, "sibling statement did not reach model")
            let saved = try await rt.converse(text: "Salva essas informações no XR", language: "pt-BR", context: nil)
            check(saved.contains("Salvei neste XR"), "plural deictic save confirms siblings")
            let recalled = try await rt.converse(text: "Qual é o nome dos meus irmãos?", language: "pt-BR", context: nil)
            check(recalled.contains("Guilherme"), "first sibling recalled")
            check(recalled.contains("Orlando Pise Júnior"), "second sibling recalled")
        }

        do {
            let store = XRPersistentMemory(url: root.appendingPathComponent("siblings-correction.json"))
            let state = XRMemoryPendingState()
            let base = DeicticFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { 4000.0 }, pendingState: state)

            let suggested = try await rt.converse(text: "O nome dos meus irmãos são Guilherme e Orlando Pires Júnior", language: "pt-BR", context: nil)
            check(suggested.contains("Quer que eu guarde"), "sibling typo suggestion created")
            let corrected = try await rt.converse(text: "Não, não é Pires, é Pise. P-I-S-I", language: "pt-BR", context: nil)
            check(corrected.contains("Corrigi"), "pending correction handled locally")
            check(base.calls == 0, "pending correction did not reach model")
            let saved = try await rt.converse(text: "Eu quero que você guarde essas informações", language: "pt-BR", context: nil)
            check(saved.contains("Salvei neste XR"), "corrected pending facts saved")
            let recalled = try await rt.converse(text: "E quem são meus irmãos?", language: "pt-BR", context: nil)
            check(recalled.contains("Guilherme"), "corrected first sibling recalled")
            check(recalled.contains("Orlando Pisi Júnior"), "spelled correction applied to second sibling")
        }

        print("PASS: \(checks) deictic memory-manager checks")
    }
}
