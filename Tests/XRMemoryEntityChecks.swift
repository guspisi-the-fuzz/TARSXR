import Foundation

@MainActor
private final class EntityFixtureRuntime: TARSRuntime {
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
struct XRMemoryEntityChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tars-entity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("memory-v1.json")
        let store = XRPersistentMemory(url: path)
        let base = EntityFixtureRuntime()
        var now = 1000.0
        let rt = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { now })

        // Identity first.
        let fatherSuggestion = try await rt.converse(text: "Meu pai chama-se Orlando Pise", language: "pt-BR", context: nil)
        check(fatherSuggestion.contains("Quer que eu guarde"), "father identity suggested")
        _ = try await rt.converse(text: "sim", language: "pt-BR", context: nil)

        // Rich entity facts are suggested together and only saved after confirmation.
        let rich = try await rt.converse(text: "Orlando Pise nasceu em Curitiba, no Paraná, em 6 de setembro de 1940, faleceu em 17 de março de 2026 e foi sepultado em 18 de março de 2026", language: "pt-BR", context: nil)
        check(rich.contains("Quer que eu guarde"), "rich father facts suggested")
        check(try store.load().facts.count == 1, "rich facts not saved before confirmation")
        let richSaved = try await rt.converse(text: "eu quero que você grave essa informação corretamente", language: "pt-BR", context: nil)
        check(richSaved.hasPrefix("Salvei neste XR:"), "rich facts confirmed")
        check(try store.load().facts.count == 5, "identity plus four attributes")
        check(base.calls == 0, "all memory operations local")

        let born = try await rt.converse(text: "Quando meu pai nasceu?", language: "pt-BR", context: nil)
        check(born == "Seu pai, Orlando Pise, nasceu em 6 de setembro de 1940.", "father birth date")
        let place = try await rt.converse(text: "Onde meu pai nasceu?", language: "pt-BR", context: nil)
        check(place.contains("Curitiba") && place.contains("Paraná"), "father birth place")
        let died = try await rt.converse(text: "Quando meu pai faleceu?", language: "pt-BR", context: nil)
        check(died == "Seu pai, Orlando Pise, faleceu em 17 de março de 2026.", "father death date")
        let buried = try await rt.converse(text: "Quando meu pai foi sepultado?", language: "pt-BR", context: nil)
        check(buried == "Seu pai, Orlando Pise, foi sepultado em 18 de março de 2026.", "father burial date")

        // Rename updates identity + every attribute, never just the relationship fact.
        let renamed = try await rt.converse(text: "Corrija Orlando Pise para Orlando Pisi", language: "pt-BR", context: nil)
        check(renamed.contains("Orlando Pisi"), "rename acknowledged")
        let docAfterRename = try store.load()
        check(docAfterRename.facts.count == 5, "rename preserves all facts")
        check(docAfterRename.facts.allSatisfy { !$0.statement.contains("Orlando Pise") && !$0.subject.contains("Orlando Pise") }, "old spelling removed from live facts")
        let diedRenamed = try await rt.converse(text: "Quando meu pai faleceu?", language: "pt-BR", context: nil)
        check(diedRenamed == "Seu pai, Orlando Pisi, faleceu em 17 de março de 2026.", "renamed entity used in attributes")

        // Birthday becomes a durable owner attribute, also confirmation-gated.
        let birthdaySuggestion = try await rt.converse(text: "Meu aniversário é 18 de março", language: "pt-BR", context: nil)
        check(birthdaySuggestion.contains("Quer que eu guarde"), "birthday suggested")
        _ = try await rt.converse(text: "sim", language: "pt-BR", context: nil)
        check(try store.load().facts.count == 6, "birthday saved")
        let birthday = try await rt.converse(text: "Quando é meu aniversário?", language: "pt-BR", context: nil)
        check(birthday.contains("18 de março"), "birthday recalled")

        // Explicit rich save bypasses suggestion but still verifies disk first.
        let secondPath = root.appendingPathComponent("explicit.json")
        let secondStore = XRPersistentMemory(url: secondPath)
        let secondBase = EntityFixtureRuntime()
        let second = MemoryTARSRuntime(underlying: secondBase, memory: { secondStore }, uptime: { now })
        let explicit = try await second.converse(text: "Grava na memória que Orlando Pisi faleceu em 17 de março de 2026", language: "pt-BR", context: nil)
        check(explicit.hasPrefix("Salvei neste XR:"), "explicit attribute save")
        check(try secondStore.load().facts.count == 1, "explicit attribute stored")

        // Reopen in a fresh runtime to prove disk persistence.
        let reopened = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: path) }, uptime: { now })
        let restart = try await reopened.converse(text: "Quando meu pai faleceu?", language: "pt-BR", context: nil)
        check(restart.contains("Orlando Pisi") && restart.contains("17 de março de 2026"), "facts survive runtime restart")
        let restartBirthday = try await reopened.converse(text: "Quando é meu aniversário?", language: "pt-BR", context: nil)
        check(restartBirthday.contains("18 de março"), "birthday survives runtime restart")

        print("PASS: \(checks) entity-memory checks; multi-attribute, rename, birthday, persistence")
    }
}
