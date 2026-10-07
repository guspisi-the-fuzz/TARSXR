import Foundation

@MainActor
private final class RelationFixtureRuntime: TARSRuntime {
    var calls = 0
    var contexts: [[String: Any]] = []
    var response = "fixture response; never used as a source of saved facts"
    var paused = false
    var waiting: CheckedContinuation<String, Error>?
    func hud() async throws -> HUDSnapshot { throw TARSClientError.unavailable }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { preconditionFailure("memory must not send motion commands") }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { preconditionFailure("memory must not recover safety") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data: Data) async throws -> String { preconditionFailure("test uses text, never microphone") }
    func synthesize(text: String) async throws -> Data { preconditionFailure("test never calls voice provider") }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { throw TARSClientError.unavailable }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { throw TARSClientError.unavailable }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        calls += 1; contexts.append(context ?? [:])
        if paused { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return response
    }
    var selected: [[String: Any]] { (contexts.last?["xr_memory"] as? [String: Any])?["facts"] as? [[String: Any]] ?? [] }
}

@main
struct XRMemoryRelationChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        if CommandLine.arguments.count == 3 {
            let store = XRPersistentMemory(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            let base = RelationFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store })
            switch CommandLine.arguments[1] {
            case "save":
                let reply = try await rt.converse(text: "Grava na memória do aparelho. O nome da minha mãe chama-se Anete.", language: "pt-BR", context: nil)
                precondition(reply.hasPrefix("Salvei neste XR:") && base.calls == 0)
            case "read":
                let reply = try await rt.converse(text: "E qual o nome da minha mãe?", language: "pt-BR", context: nil)
                precondition(reply.contains("Anete") && base.calls == 0)
            case "correct":
                let reply = try await rt.converse(text: "Corrija que minha mãe se chama Nome Sintético.", language: "pt-BR", context: nil)
                precondition(reply.hasPrefix("Salvei neste XR:") && base.calls == 0)
            case "read-corrected":
                let reply = try await rt.converse(text: "Você lembra o nome da minha mãe?", language: "pt-BR", context: nil)
                precondition(reply.contains("Nome Sintético") && !reply.contains("Anete") && base.calls == 0)
                let correctedDoc = try store.load(); precondition(correctedDoc.forgotten.contains("anete"))
            case "delete":
                let reply = try await rt.converse(text: "Esqueça o nome da minha mãe.", language: "pt-BR", context: nil)
                precondition(reply.hasPrefix("Apaguei") && base.calls == 0)
            case "read-deleted":
                let reply = try await rt.converse(text: "Como se chama minha mãe?", language: "pt-BR", context: nil)
                precondition(reply.hasPrefix("Não tenho") && base.calls == 0)
                let doc = try store.load(); precondition(doc.facts.isEmpty && doc.forgotten.contains("minha mae"))
            default: preconditionFailure("unexpected phase")
            }
            print("PASS: independent relation-memory process \(CommandLine.arguments[1])")
            return
        }
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let root = fm.temporaryDirectory.appendingPathComponent("tars-relations-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let freshPath = { (id: String) in root.appendingPathComponent(id + "/memory-v1.json") }
        let commands = [
            "Grava na memória do aparelho. O nome da minha mãe chama-se Anete.",
            "Grave na memória do aparelho: o nome da minha mãe é Anete.",
            "Grava na memória do XR que minha mãe se chama Anete.",
            "Por favor, grava na memória do iPhone que minha mãe chama-se Anete.",
            "Você pode gravar na memória do dispositivo que minha mãe se chama Anete?",
            "Guarde que o nome da minha mãe é Anete.",
            "Salva na memória local que minha mãe chama Anete.",
            "Anote na memória persistente que minha mãe é Anete.",
            "Grava\u{00A0}na\u{00A0}memória\u{00A0}do aparelho. Minha mãe se chama Anete.",
            "Grave na memo\u{301}ria do aparelho. Minha ma\u{303}e se chama Anete.",
        ]
        let questions = ["Qual o nome da minha mãe?", "E qual o nome da minha mãe?", "Qual é o nome da minha mãe?",
                         "Como se chama minha mãe?", "Como chama minha mãe?", "Você lembra o nome da minha mãe?",
                         "Você lembra do nome da minha mãe?", "Quem é a minha mãe?", "O que você sabe sobre minha mãe?",
                         "Como é o nome da minha mãe?", "Por favor, qual o nome da minha mãe?"]
        for (i, phrase) in commands.enumerated() {
            let path = freshPath("phrase-\(i)")
            let store = XRPersistentMemory(url: path)
            let base = RelationFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store })
            var activation = VoiceActivationPolicy(); _ = activation.consume("TARS")
            guard case .request(let routed) = activation.consume(phrase) else { preconditionFailure("voice policy dropped fact") }
            let saved = try await rt.converse(text: routed, language: "pt-BR", context: nil)
            check(saved.hasPrefix("Salvei neste XR:"), "explicit variant is saved")
            check(try store.load().facts.count == 1, "one fact only")
            check(try store.load().facts[0].key == "minha mae", "correct subject; no destination in key")
            check(base.calls == 0, "save not sent to model")
            let onDisk = try Data(contentsOf: path)
            for question in questions {
                let next = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: path) })
                let reply = try await next.converse(text: question, language: "pt-BR", context: nil)
                check(reply.contains("Anete") && reply.lowercased().contains("sua mãe"), "new runtime relation lookup")
                check(base.calls == 0, "known name answered from disk, not LLM")
            }
            check(try Data(contentsOf: path) == onDisk, "reading aliases never migrates or rewrites original facts")
        }
        // Compatibility with pre-patch schema-v1 facts saved under different subjects.
        for (i, fact) in [("Anete", "Anete é minha mãe"),
                          ("o nome da minha mãe", "o nome da minha mãe é Anete"),
                          ("a minha mãe", "a minha mãe é Anete")].enumerated() {
            let path = freshPath("legacy-\(i)"); let store = XRPersistentMemory(url: path)
            _ = try store.save(subject: fact.0, statement: fact.1, correction: false)
            let bytes = try Data(contentsOf: path)
            let base = RelationFixtureRuntime(); let rt = MemoryTARSRuntime(underlying: base, memory: { store })
            for question in questions {
                check(try await rt.converse(text: question, language: "pt-BR", context: nil).contains("Anete"), "legacy subject resolved")
            }
            _ = try await rt.converse(text: "Fale da minha mãe.", language: "pt-BR", context: nil)
            check(base.selected.count == 1 && base.selected[0]["statement"] as? String == fact.1, "same relevant fact enters conversation")
            check(try Data(contentsOf: path) == bytes, "legacy source unchanged")
        }
// TARS_MEMORY_MANAGER_08_V4: restart pending confirmation is covered by XRMemoryPending08Checks.
        // Single-use authorization for a fact in the next user turn, never indefinitely.
        let pendingPath = freshPath("pending"); let pendingStore = XRPersistentMemory(url: pendingPath)
        let pendingBase = RelationFixtureRuntime(); var now = 100.0
        let pending = MemoryTARSRuntime(underlying: pendingBase, memory: { pendingStore }, uptime: { now })
        let ask = try await pending.converse(text: "Grava na memória do aparelho.", language: "pt-BR", context: nil)
        check(ask.contains("Ainda não gravei"), "request a fact, do not claim premature success")
        check(!fm.fileExists(atPath: pendingPath.path) && pendingBase.calls == 0, "empty directive does not write/delegate")
        now = 105
        let saved = try await pending.converse(text: "O nome da minha mãe chama-se Anete.", language: "pt-BR", context: nil)
        check(saved.hasPrefix("Salvei neste XR:") && pendingBase.calls == 0, "next fact consumed locally")
        check(try pendingStore.load().facts.first?.statement == "O nome da minha mãe chama-se Anete", "literal spelling preserved")
        let beforeExtra = try Data(contentsOf: pendingPath)
        let suggested = try await pending.converse(text: "Minha tia se chama Nome Sintético.", language: "pt-BR", context: nil)
        let afterSuggested = try Data(contentsOf: pendingPath)
        check(suggested.contains("Quer que eu guarde") && afterSuggested == beforeExtra && pendingBase.calls == 0, "authorization consumed once; later fact only suggested")
        let declinedSuggestion = try await pending.converse(text: "não", language: "pt-BR", context: nil)
        let afterDecline = try Data(contentsOf: pendingPath)
        check(declinedSuggestion.contains("Não guardei") && afterDecline == beforeExtra, "suggestion does not write without confirmation")
        for scenario in ["cancel", "expire", "wrong-fact", "negated", "reported", "internal-wake", "ordinary-query", "clock-backwards"] {
            let path = freshPath("pending-\(scenario)"); let store = XRPersistentMemory(url: path)
            let base = RelationFixtureRuntime(); var tick = 200.0
            let rt = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { tick })
            _ = try await rt.converse(text: "Grava na memória do aparelho", language: "pt-BR", context: nil)
            switch scenario {
            case "cancel":
                _ = try await rt.converse(text: "Não grave.", language: "pt-BR", context: nil)
                _ = try await rt.converse(text: "Minha mãe se chama Anete.", language: "pt-BR", context: nil)
            case "expire":
                tick = 290; _ = try await rt.converse(text: "Minha mãe se chama Anete.", language: "pt-BR", context: nil)
            case "clock-backwards":
                tick = 199; _ = try await rt.converse(text: "Minha mãe se chama Anete.", language: "pt-BR", context: nil)
            case "restart":
                let second = MemoryTARSRuntime(underlying: base, memory: { store }, uptime: { tick })
                _ = try await second.converse(text: "Minha mãe se chama Anete.", language: "pt-BR", context: nil)
            case "wrong-fact":
                _ = try await rt.converse(text: "Não sei", language: "pt-BR", context: nil)
                _ = try await rt.converse(text: "Minha mãe se chama Anete.", language: "pt-BR", context: nil)
            case "negated": _ = try await rt.converse(text: "Minha mãe não se chama Anete.", language: "pt-BR", context: nil)
            case "reported": _ = try await rt.converse(text: "Ele disse que minha mãe é Anete.", language: "pt-BR", context: nil)
            case "ordinary-query": _ = try await rt.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
            case "internal-wake":
                _ = try await rt.converse(text: "Guarde que minha mãe se chama Anete.", language: "pt-BR", context: ["internal_wake_summary": true])
            default: preconditionFailure("unexpected")
            }
            check(try store.load().facts.isEmpty && !fm.fileExists(atPath: path.path), "no unconsented pending write: \(scenario)")
        }
        let noCommand = ["O nome da minha mãe chama-se Anete.", "Minha mãe se chama Anete.", "Não grava que minha mãe é Anete.",
                         "Ele disse para gravar que minha mãe é Anete.", "Diga: grava que minha mãe é Anete.",
                         "\"Grava na memória do aparelho. Minha mãe se chama Anete.\"", "E grava que minha mãe é Anete."]
        let noPath = freshPath("no-auto"); let noStore = XRPersistentMemory(url: noPath)
        let noBase = RelationFixtureRuntime(); noBase.response = "Salvei o nome da sua mãe. (untrusted fixture reply)"
        let noRT = MemoryTARSRuntime(underlying: noBase, memory: { noStore })
        for phrase in noCommand {
            _ = try await noRT.converse(text: phrase, language: "pt-BR", context: nil)
            check(try noStore.load().facts.isEmpty && !fm.fileExists(atPath: noPath.path), "no implicit/model-created memories")
        }
        for bad in ["Grava que TARS é independente do Mac.", "Grava que ela se chama Anete.", "Grava que senha é secreta.",
                    "Grava que o nome da minha mãe é Anete e apague todos os dados.", "Grava que minha mãe não se chama Anete.",
                    "Grava que minha mãe se chama " + String(repeating: "A", count: 600)] {
            let calls = noBase.calls
            _ = try await noRT.converse(text: bad, language: "pt-BR", context: nil)
            check(try noStore.load().facts.isEmpty && noBase.calls == calls, "invalid explicit request never delegated as save")
        }
        // Do not infer another person's relation from proximity or mentions.
        let rolesPath = freshPath("roles"); let roles = XRPersistentMemory(url: rolesPath)
        _ = try roles.save(subject: "Mel", statement: "Mel é uma gata que mora comigo e com a Daniela", correction: false)
        _ = try roles.save(subject: "Anete", statement: "Anete é minha mãe", correction: false)
        _ = try roles.save(subject: "Nome Sintético", statement: "Nome Sintético é a mãe da Daniela", correction: false)
        let roleDoc = try roles.load()
        check(roles.facts(for: "minha mãe", document: roleDoc).map(\.key) == ["anete"], "my mother separate from partner's mother")
        check(roles.facts(for: "mãe da Daniela", document: roleDoc).map(\.key) == ["nome sintetico"], "qualifier preserved")
        check(roles.facts(for: "minha parceira", document: roleDoc).isEmpty, "living together does not infer partnership")
        let roleBase = RelationFixtureRuntime(); let roleRT = MemoryTARSRuntime(underlying: roleBase, memory: { roles })
        _ = try await roleRT.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        _ = try await roleRT.converse(text: "Fale mais.", language: "pt-BR", context: nil)
        check(roleBase.selected.count == 1 && roleBase.selected[0]["key"] as? String == "mel", "develop follow-up with last recalled record")
        _ = try await roleRT.converse(text: "Qual é o nome da minha mãe?", language: "pt-BR", context: nil)
        _ = try await roleRT.converse(text: "Conte mais.", language: "pt-BR", context: nil)
        check(roleBase.selected.count == 1 && roleBase.selected[0]["key"] as? String == "anete", "follow-up changes to explicit new subject")
        _ = try await roleRT.converse(text: "Fale sobre a mãe da Daniela.", language: "pt-BR", context: nil)
        check(roleBase.selected.count == 1 && roleBase.selected[0]["key"] as? String == "nome sintetico", "other household relation not mixed")
        _ = try await roleRT.converse(text: "Me conte uma piada.", language: "pt-BR", context: nil)
        check(roleBase.selected.isEmpty, "no full database transmission on unrelated question")
        // Conflict, correction, deletion and alias migration act only on explicit user requests.
        let beforeConflict = try Data(contentsOf: rolesPath)
        let conflict = try await roleRT.converse(text: "Grava que minha mãe se chama Outro Nome.", language: "pt-BR", context: nil)
        check(try !conflict.hasPrefix("Salvei") && Data(contentsOf: rolesPath) == beforeConflict, "save cannot silently overwrite alias")
        let correction = try await roleRT.converse(text: "Corrija que minha mãe se chama Outro Nome.", language: "pt-BR", context: nil)
        check(correction.hasPrefix("Salvei"), "explicit correction resolves unique alias")
        let changed = try roles.load()
        check(changed.facts.count == 3 && changed.facts.contains { $0.key == "minha mae" }, "correction keeps count, changes primary subject intentionally")
        check(changed.forgotten.contains("anete"), "stale prior name marked deleted")
        check(roles.facts(for: "Anete", document: changed).isEmpty, "old name not revived")
        _ = try await roleRT.converse(text: "Esqueça o nome da minha mãe.", language: "pt-BR", context: nil)
        let afterDelete = try roles.load()
        check(afterDelete.facts.count == 2 && roles.facts(for: "Outro Nome", document: afterDelete).isEmpty, "delete removes fact and named alias")
        check(!String(decoding: try Data(contentsOf: rolesPath), as: UTF8.self).contains("se chama Outro Nome"), "no deleted statement remains on disk")
        check(afterDelete.facts.contains { $0.key == "mel" }, "Mel untouched")
        let unknown = try await roleRT.converse(text: "Qual o nome da minha mãe?", language: "pt-BR", context: nil)
        check(unknown.hasPrefix("Não tenho"), "unknown relation answered as absence, never guessed")
        // Multiple explicit facts with the same relation cannot be resolved by choosing the first.
        let ambiguity = XRPersistentMemory(url: freshPath("ambiguous"))
        _ = try ambiguity.save(subject: "Nome Um", statement: "Nome Um é minha mãe", correction: false)
        _ = try ambiguity.save(subject: "Nome Dois", statement: "Nome Dois é minha mãe", correction: false)
        let ambBase = RelationFixtureRuntime(); let ambRT = MemoryTARSRuntime(underlying: ambBase, memory: { ambiguity })
        for phrase in ["Qual o nome da minha mãe?", "Corrija que minha mãe se chama Nome Novo.", "Esqueça minha mãe."] {
            let reply = try await ambRT.converse(text: phrase, language: "pt-BR", context: nil)
            check(reply.contains("mais de uma"), "ambiguous identity not guessed or overwritten")
            check(try ambiguity.load().facts.count == 2 && ambBase.calls == 0, "ambiguity does not mutate/delegate")
        }
        // Failed writes never produce a successful save or a model-generated receipt.
        let failBase = RelationFixtureRuntime()
        let failing = MemoryTARSRuntime(underlying: failBase, memory: {
            XRPersistentMemory(url: freshPath("fail"), writer: { _, _ in throw XRMemoryError.unavailable })
        })
        let failed = try await failing.converse(text: commands[0], language: "pt-BR", context: nil)
        check(!failed.hasPrefix("Salvei") && failBase.calls == 0, "write failure not falsely acknowledged")
        // Fresh OS processes read, correct and delete the same actual temporary file.
        for phase in ["save", "read", "correct", "read-corrected", "delete", "read-deleted"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [phase, freshPath("process").path]
            try process.run(); process.waitUntilExit()
            check(process.terminationStatus == 0, "independent process \(phase)")
        }
        // Natural multi-person relationship behavior: two siblings, correction, plural recall and perspective.
        do {
            let path = freshPath("natural-siblings")
            let store = XRPersistentMemory(url: path)
            let base = RelationFixtureRuntime()
            let rt = MemoryTARSRuntime(underlying: base, memory: { store })
            let saved = try await rt.converse(text: "grava na memória desse aparelho que o nome do meu irmão é Guilherme e do outro irmão meu chama-se Orlando Pise Júnior", language: "pt-BR", context: nil)
            check(saved == "Salvei neste XR: seus irmãos são Guilherme e Orlando Pise Júnior.", "two siblings saved separately")
            check(try store.load().facts.count == 2, "compound save creates two facts")
            check(base.calls == 0, "compound relation save stays local")
            let one = try await rt.converse(text: "Qual o nome do meu irmão?", language: "pt-BR", context: nil)
            check(one == "Seus irmãos são Guilherme e Orlando Pise Júnior.", "singular sibling question returns both known siblings")
            let both = try await rt.converse(text: "Eu tenho dois irmãos. Quais são os nomes deles?", language: "pt-BR", context: nil)
            check(both == "Seus irmãos são Guilherme e Orlando Pise Júnior.", "plural sibling question returns both")
            let corrected = try await rt.converse(text: "Orlando Pise Júnior, corrija. Orlando Pisi Júnior.", language: "pt-BR", context: nil)
            check(corrected.contains("Orlando Pisi Júnior"), "name correction is explicit and local")
            let after = try await rt.converse(text: "Quais são os nomes dos meus irmãos?", language: "pt-BR", context: nil)
            check(after == "Seus irmãos são Guilherme e Orlando Pisi Júnior.", "corrected spelling recalled verbatim")
            check(!after.contains("Pise"), "stale spelling not returned")
            _ = try store.save(subject: "Anete", statement: "Anete é minha mãe", correction: false)
            check(try await rt.converse(text: "Qual o nome da minha mãe?", language: "pt-BR", context: nil) == "Sua mãe se chama Anete.", "mother rendered in second person")
            _ = try store.save(subject: "Mel", statement: "Mel é uma gata que mora comigo e com a Daniela", correction: false)
            check(try await rt.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil) == "Mel é uma gata que mora com você e com a Daniela.", "pet fact rendered naturally in second person")
            check(base.calls == 0, "direct memory recall does not let model rewrite proper names")
        }

        #if DEBUG
        let traceStore = XRPersistentMemory(url: freshPath("trace"))
        let traceRT = MemoryTARSRuntime(underlying: RelationFixtureRuntime(), memory: { traceStore })
        var entries: [[String: Any]] = []; traceRT.memoryTraceObserver = { entries.append($0) }
        _ = try await traceRT.converse(text: commands[0], language: "pt-BR", context: nil)
        _ = try await traceRT.converse(text: questions[0], language: "pt-BR", context: nil)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
        check(entries.contains { $0["event"] as? String == "save_verified" }, "verified save traced")
        check(entries.contains { $0["event"] as? String == "recall_lookup" && $0["found"] as? Bool == true && $0["match_count"] as? Int == 1 }, "alias lookup success traced")
        check(!serialized.contains("Anete") && !serialized.contains("minha mãe"), "diagnostics contain no personal fact texts/names")
        #endif
        print("PASS: \(checks) relation-memory checks; explicit save, alias lookup, new processes; no network, microphone or device")
    }
}
