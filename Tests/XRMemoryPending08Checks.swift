import Foundation

@MainActor
private final class PendingFixtureRuntime: TARSRuntime {
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
struct XRMemoryPending08Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-memory-pending08-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = XRPersistentMemory(url: root.appendingPathComponent("memory-v1.json"))
        let state = XRMemoryPendingState()
        let base1 = PendingFixtureRuntime()
        var now = 1000.0
        let rt1 = MemoryTARSRuntime(underlying: base1, memory: { store }, uptime: { now }, pendingState: state)

        let identity = try await rt1.converse(text: "Guarde que meu pai se chama Orlando Pise", language: "pt-BR", context: nil)
        check(identity.contains("Salvei neste XR"), "explicit father identity saved")
        check(try store.load().facts.count == 1, "identity persisted")
        check(base1.calls == 0, "explicit save stayed local")

        let suggestion = try await rt1.converse(text: "A data de aniversário do meu pai é 6 de setembro de 1940. O nome dele é Orlando Pise", language: "pt-BR", context: nil)
        check(suggestion.contains("Quer que eu guarde"), "birth suggestion created")
        check(try store.load().facts.count == 1, "suggestion not yet written")

        // Simulate SwiftUI/runtime recreation between the prompt and the spoken confirmation.
        let base2 = PendingFixtureRuntime()
        let rt2 = MemoryTARSRuntime(underlying: base2, memory: { store }, uptime: { now }, pendingState: state)
        let saved = try await rt2.converse(text: "Sim, eu quero", language: "pt-BR", context: nil)
        check(saved.contains("Salvei neste XR"), "confirmation survives runtime recreation")
        check(try store.load().facts.count >= 2, "birth persisted")
        check(base2.calls == 0, "confirmation never reached model")

        let recalled = try await rt2.converse(text: "Qual é a data de nascimento do meu pai?", language: "pt-BR", context: nil)
        check(recalled.contains("6 de setembro de 1940"), "birth recalled")
        check(recalled.contains("Orlando Pise"), "father entity retained")

        let duplicate = try await rt2.converse(text: "Sim, eu quero", language: "pt-BR", context: nil)
        check(duplicate == "Não há nenhuma gravação de memória aguardando confirmação.", "duplicate confirmation handled locally")
        check(base2.calls == 0, "duplicate confirmation not sent to model")

        let incomplete = try await rt2.converse(text: "Eu quero que você guarde a data de aniversário do meu pai e o nome dele", language: "pt-BR", context: nil)
        check(incomplete != "REMOTE", "incomplete memory command stayed local")
        check(base2.calls == 0, "incomplete memory command did not reach model")

        // Pending suggestion survives an internal wake-summary call.
        let suggestion2 = try await rt2.converse(text: "Meu aniversário é 18 de março", language: "pt-BR", context: nil)
        check(suggestion2.contains("Quer que eu guarde"), "birthday suggestion created")
        _ = try await rt2.converse(text: "wake up", language: "pt-BR", context: ["internal_wake_summary": true])
        check(base2.calls == 1, "internal wake still uses underlying runtime")
        let birthdaySaved = try await rt2.converse(text: "Pode guardar", language: "pt-BR", context: nil)
        check(birthdaySaved.contains("Salvei neste XR"), "confirmation survives internal wake turn")
        let birthday = try await rt2.converse(text: "Quando é meu aniversário?", language: "pt-BR", context: nil)
        check(birthday.contains("18 de março"), "owner birthday recalled")

        // Expired pending state is cleared and a bare confirmation still stays local.
        let expStore = XRPersistentMemory(url: root.appendingPathComponent("expire.json"))
        let expState = XRMemoryPendingState()
        let expBase = PendingFixtureRuntime()
        let expRT = MemoryTARSRuntime(underlying: expBase, memory: { expStore }, uptime: { now }, pendingState: expState)
        _ = try await expRT.converse(text: "Minha mãe se chama Anete", language: "pt-BR", context: nil)
        now += 61
        let expired = try await expRT.converse(text: "sim", language: "pt-BR", context: nil)
        check(expired == "Não há nenhuma gravação de memória aguardando confirmação.", "expired confirmation handled locally")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("expire.json").path), "expired candidate not saved")
        check(expBase.calls == 0, "expired bare confirmation not sent to model")

        print("PASS: \(checks) pending-memory process-state checks")
    }
}
