import Foundation

@MainActor
private final class MemoryFixtureRuntime: TARSRuntime {
    var calls: [String] = []
    var contexts: [[String: Any]] = []
    var fail: Error?
    var waiting: CheckedContinuation<String, Error>?
    var pause = false
    var response = "fixture answer"
    func hud() async throws -> HUDSnapshot { calls.append("hud"); throw TARSClientError.unavailable }
    func telemetry() async throws -> TARSTelemetry {
        calls.append("telemetry")
        return TARSTelemetry(motionActive: false, emergencyStop: true, estopGeneration: 3, recoveryRequired: true, panDeg: 0)
    }
    func recover() async throws { calls.append("recover"); throw TARSClientError.rejected("STOP") }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply {
        calls.append(action); return TARSCommandReply(status: "REJECTED", reason: "STOP", telemetry: nil)
    }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply {
        calls.append("vision"); return VisionReply(description: "fixture", source: source, live_camera: false, actions_enabled: false, metric_geometry_available: false)
    }
    func transcribe(data: Data) async throws -> String { calls.append("transcribe"); return "fixture" }
    func synthesize(text: String) async throws -> Data { calls.append("synthesize"); return Data([1,2]) }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        calls.append("converse"); contexts.append(context ?? [:])
        if let fail { throw fail }
        if pause { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return response
    }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { calls.append("streamSpeech"); try receive(Data([1])) }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws { calls.append("streamConversation"); receiveText("fixture"); try receive(Data([1])) }
}

@main
struct XRMemoryChecks {
    @MainActor static func main() async throws {
        if let phase = ProcessInfo.processInfo.environment["TARS_MEMORY_PROCESS_PHASE"],
           let path = ProcessInfo.processInfo.environment["TARS_MEMORY_PROCESS_FILE"] {
            let memory = XRPersistentMemory(url: URL(fileURLWithPath: path))
            switch phase {
            case "save": _ = try memory.save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
            case "read": let state = try memory.load(); precondition(state.facts.first?.statement == "a Mel é minha gata")
            case "correct": _ = try memory.save(subject: "a Mel", statement: "a Mel é minha cachorra", correction: true)
            case "read-corrected": let state = try memory.load(); precondition(state.facts.first?.statement == "a Mel é minha cachorra")
            case "delete": _ = try memory.forget(subject: "Mel")
            case "read-deleted":
                let state = try memory.load(); precondition(state.facts.isEmpty && state.forgotten == ["mel"])
            default: preconditionFailure("unexpected test phase")
            }
            print("PASS: new-process memory phase \(phase)")
            return
        }
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1 }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tars-memory-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for phase in ["save", "read", "correct", "read-corrected", "delete", "read-deleted"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var env = ProcessInfo.processInfo.environment
            env["TARS_MEMORY_PROCESS_PHASE"] = phase
            env["TARS_MEMORY_PROCESS_FILE"] = root.appendingPathComponent("process/memory.json").path
            process.environment = env
            try process.run(); process.waitUntilExit()
            check(process.terminationStatus == 0, "independent process \(phase)")
        }
        let file = root.appendingPathComponent("owner/memory-v1.json")
        let store = XRPersistentMemory(url: file, now: { 1791310000 })
        check(try store.load().facts.isEmpty, "starts empty; no seeded personal knowledge")
        check(!fm.fileExists(atPath: file.path), "reading empty memory does not invent facts")
        check(XRPersistentMemory.key("a MÉL!") == "mel", "case/accent/article normalization")
        let parserCases: [(String, XRMemoryIntent)] = [
            ("lembre-se de que a Mel é minha gata", .save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)),
            ("esqueça tudo sobre a Mel", .forget("a Mel")),
            ("remember when Mel is young", .help),
            ("guarde: TARS é independente do Mac", .help),
            ("guarde: senha é secreta", .help),
            ("guarde: a memória: Mel é minha gata", .help),
            ("guarde: a Mel é minha gata", .save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)),
            ("Guarde que a Mel é minha gata.", .save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)),
            ("corrija, a Mel é minha cachorra", .save(subject: "a Mel", statement: "a Mel é minha cachorra", correction: true)),
            ("remember that Mel is my cat", .save(subject: "Mel", statement: "Mel is my cat", correction: false)),
            ("Correct: Mel is my dog.", .save(subject: "Mel", statement: "Mel is my dog", correction: true)),
            ("esqueça a Mel.", .forget("a Mel")), ("forget Mel", .forget("Mel")),
            ("quem é a Mel?", .recall("a Mel", explicit: false)),
            ("o que você lembra sobre Mel?", .recall("Mel", explicit: true)),
            ("what do you remember about Mel?", .recall("Mel", explicit: true)),
            ("Quem é Sócrates?", .recall("Sócrates", explicit: false)),
            ("diga guarde a Mel é minha gata", .ordinary), ("a Mel é minha gata", .ordinary),
            ("eu disse esqueça Mel", .ordinary), ("guarde", .help), ("esqueça tudo", .help),
            ("guarde que ela é minha gata", .help), ("guarde a Mel", .help)
        ]
        for (text, intent) in parserCases { check(XRMemoryIntent.parse(text) == intent, "parse: \(text)") }
        let fact = try store.save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
        check(fact.source == "explicit_user" && fact.scope == "local_owner", "fact provenance/scope")
        let doc = try store.load()
        check(doc.facts.count == 1 && doc.facts[0] == fact, "disk readback")
        let restarted = XRPersistentMemory(url: file)
        check(try restarted.load().facts[0].statement == fact.statement, "new instance restores memory")
        check(try restarted.load().ownerID == doc.ownerID, "stable local owner across restart")
        _ = try restarted.save(subject: "a Mel", statement: fact.statement, correction: false)
        check(try restarted.load().revision == doc.revision, "idempotent explicit save")
        do { _ = try store.save(subject: "a Mel", statement: "a Mel é outra", correction: false); preconditionFailure("silent replacement") }
        catch XRMemoryError.changed { count += 1 }
        _ = try store.save(subject: "a Mel", statement: "a Mel é minha cachorra", correction: true)
        let corrected = try store.load()
        check(corrected.revision != doc.revision && corrected.facts.count == 1, "correction advances epoch")
        check(corrected.facts[0].createdAt == fact.createdAt, "creation provenance retained")
        check(try XRPersistentMemory(url: file).load().facts[0].statement.contains("cachorra"), "correction survives restart")
        do { _ = try store.save(subject: "Pina", statement: "Pina é uma gata", correction: true); preconditionFailure("correction silently created") }
        catch XRMemoryError.missing { count += 1 }
        let beforeFailure = try Data(contentsOf: file)
        let broken = XRPersistentMemory(url: file, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        do { _ = try broken.save(subject: "Pina", statement: "Pina é uma gata", correction: false); preconditionFailure("write falsely confirmed") }
        catch XRMemoryError.unavailable { count += 1 }
        check(try Data(contentsOf: file) == beforeFailure, "failure retains previous file")
        let voidWriter = XRPersistentMemory(url: file, writer: { _, _ in })
        do { _ = try voidWriter.forget(subject: "Mel"); preconditionFailure("no-op writer confirmed") }
        catch XRMemoryError.unavailable { count += 1 }
        check(try store.forget(subject: "Mel"), "forget known memory")
        let deleted = try XRPersistentMemory(url: file).load()
        check(deleted.facts.isEmpty && deleted.forgotten == ["mel"], "forget persists only negative key")
        check(!String(data: try Data(contentsOf: file), encoding: .utf8)!.contains("cachorra"), "deleted statement absent on disk")
        check(try !store.forget(subject: "Mel"), "idempotent delete")
        _ = try store.save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
        check(try store.load().forgotten.isEmpty, "explicit relearning permitted")
        _ = try store.save(subject: "a Daniela", statement: "a Daniela é minha parceira", correction: false)
        let selected = store.context(for: "Fale da Mel", document: try store.load())
        let selectedFacts = selected["facts"] as! [[String: Any]]
        check(selectedFacts.count == 1 && selectedFacts[0]["key"] as? String == "mel", "only relevant fact selected")
        check((store.context(for: "caramelo", document: try store.load())["facts"] as! [[String: Any]]).isEmpty, "word boundaries, no partial subject match")
        check(!String(data: try JSONSerialization.data(withJSONObject: selected), encoding: .utf8)!.contains("Daniela"), "unrelated private record not uploaded")

        let base = MemoryFixtureRuntime()
        let runtime = MemoryTARSRuntime(underlying: base, memory: { store })
        let recalled = try await runtime.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        check(recalled.contains("sua gata") && base.calls.isEmpty, "exact recall is local, no AI or motion")
        _ = try await runtime.converse(text: "E ela?", language: "pt-BR", context: ["sentinel": 7])
        check(base.contexts.last?["sentinel"] as? Int == 7, "existing request context preserved")
        let envelope = base.contexts.last?["xr_memory"] as! [String: Any]
        check((envelope["facts"] as! [[String: Any]]).first?["key"] as? String == "mel", "follow-up retrieves current record")
        _ = try await runtime.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        let contextCountBeforeBareConfirmation = base.contexts.count
        let bareConfirmation = try await runtime.converse(text: "sim", language: "pt-BR", context: nil)
        check(bareConfirmation == "Não há nenhuma gravação de memória aguardando confirmação.",
              "bare confirmation without pending memory stays local")
        check(base.contexts.count == contextCountBeforeBareConfirmation,
              "bare confirmation never reaches model")
        _ = try await runtime.converse(text: "Quem é Sócrates?", language: "pt-BR", context: nil)
        check(base.calls.last == "converse", "unknown general knowledge not hijacked")
        let afterLocalReply = base.contexts.last?["xr_memory"] as! [String: Any]
        check(afterLocalReply["revision"] as? String != envelope["revision"] as? String,
              "local recall supersedes pending remote confirmation epoch")
        let before = base.calls.count
        let saved = try await runtime.converse(text: "guarde: minha bebida favorita é café", language: "pt-BR", context: nil)
        check(saved.hasPrefix("Salvei") && base.calls.count == before, "explicit save acknowledged only locally")
        check(try store.load().facts.count == 3, "preference stored using explicit subject")
        _ = try await runtime.converse(text: "a Pina é minha gata", language: "pt-BR", context: nil)
        check(try store.load().facts.count == 3, "ordinary facts are not silently extracted")
        let forgot = try await runtime.converse(text: "esqueça a Mel", language: "pt-BR", context: nil)
        check(forgot.hasPrefix("Apaguei"), "explicit forget acknowledged")
        let again = MemoryTARSRuntime(underlying: base, memory: { XRPersistentMemory(url: file) })
        let forgottenRecall = try await again.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        check(forgottenRecall.hasPrefix("Não tenho"), "forget survives runtime restart")
        _ = try await again.converse(text: "explique a Mel", language: "pt-BR", context: nil)
        let afterDelete = base.contexts.last?["xr_memory"] as! [String: Any]
        check((afterDelete["facts"] as! [[String: Any]]).isEmpty, "deleted facts not sent to Core")
        check(afterDelete["revision"] as? String != envelope["revision"] as? String, "Core history invalidation tag")
        let badRuntime = MemoryTARSRuntime(underlying: base, memory: { broken })
        let failedSave = try await badRuntime.converse(text: "guarde: a Pina é minha gata", language: "pt-BR", context: nil)
        check(!failedSave.hasPrefix("Salvei"), "failure never claims success")
        let failedOpen = MemoryTARSRuntime(underlying: base, memory: { throw XRMemoryError.unavailable })
        let failedRead = try await failedOpen.converse(text: "quem é a Mel?", language: "pt-BR", context: nil)
        check(failedRead.contains("Não consegui"), "read failure does not hallucinate remembered facts")

        let corruptURL = root.appendingPathComponent("corrupt.json")
        try Data("{broken".utf8).write(to: corruptURL)
        let corrupt = XRPersistentMemory(url: corruptURL)
        do { _ = try corrupt.save(subject: "Mel", statement: "Mel is my cat", correction: false); preconditionFailure("corruption overwritten") }
        catch XRMemoryError.invalid { count += 1 }
        check(try Data(contentsOf: corruptURL) == Data("{broken".utf8), "corruption preserved for recovery")
        let tooBig = root.appendingPathComponent("too-big.json")
        try Data(repeating: 32, count: XRPersistentMemory.maxBytes + 1).write(to: tooBig)
        do { _ = try XRPersistentMemory(url: tooBig).load(); preconditionFailure("oversize file loaded") }
        catch XRMemoryError.invalid { count += 1 }
        let link = root.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        do { _ = try XRPersistentMemory(url: link).load(); preconditionFailure("followed symlink") }
        catch XRMemoryError.invalid { count += 1 }

        // Editing while a network response waits must suppress the stale answer.
        _ = try store.save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
        base.pause = true
        let pending = Task { @MainActor in try await runtime.converse(text: "Explique a Mel", language: "pt-BR", context: nil) }
        for _ in 0..<100 where base.waiting == nil { await Task.yield() }
        check(base.waiting != nil, "in-flight fixture started")
        _ = try store.forget(subject: "Mel")
        base.waiting?.resume(returning: "STALE PRIVATE FACT"); base.waiting = nil; base.pause = false
        let discarded = try await pending.value
        check(!discarded.contains("STALE PRIVATE FACT"), "stale response after delete suppressed")
        let countBeforeCancel = try store.load().facts.count
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.converse(text: "guarde: a Pina é minha gata", language: "pt-BR", context: nil)
        }
        do { _ = try await cancelled.value; preconditionFailure("cancelled mutation succeeded") }
        catch is CancellationError { count += 1 }
        check(try store.load().facts.count == countBeforeCancel, "cancelled save writes nothing")
        check(!base.calls.contains("recover") && !base.calls.contains("MOVE"), "memory operations never actuate")
        let telemetry = try await runtime.telemetry()
        check(telemetry.recoveryRequired && telemetry.emergencyStop && !telemetry.motionActive, "safety telemetry unchanged")
        do { try await runtime.recover(); preconditionFailure("recovery guard bypassed") }
        catch TARSClientError.rejected { count += 1 }
        let audio = try await runtime.synthesize(text: "teste")
        check(audio == Data([1,2]) && base.calls.last == "synthesize", "voice is still delegated unchanged")
        base.fail = TARSClientError.ai("AI_BUSY")
        do { _ = try await runtime.converse(text: "fala", language: "pt-BR", context: nil); preconditionFailure("provider error swallowed") }
        catch TARSClientError.ai(let code) { check(code == "AI_BUSY", "provider failure propagated") }
        base.fail = nil
        let capacity = XRPersistentMemory(url: root.appendingPathComponent("capacity/memory.json"))
        for i in 0..<XRPersistentMemory.maxFacts {
            _ = try capacity.save(subject: "Pessoa \(i)", statement: "Pessoa \(i) is a fixture", correction: false)
            check(try XRPersistentMemory(url: root.appendingPathComponent("capacity/memory.json")).load().facts.count == i + 1, "relaunch \(i)")
        }
        do { _ = try capacity.save(subject: "overflow", statement: "overflow is a fixture", correction: false); preconditionFailure("capacity silently evicted") }
        catch XRMemoryError.full { count += 1 }
        check(try capacity.load().facts.count == XRPersistentMemory.maxFacts, "capacity preserves all prior facts")
        for subject in ["ela", "ele", "it", "you", String(repeating: "x", count: 81)] {
            do { _ = try store.save(subject: subject, statement: "a fact", correction: false); preconditionFailure("invalid subject saved") }
            catch XRMemoryError.unsupported { count += 1 }
        }
        // Wire fixture consumed by the Python contract tests; contains synthetic facts only.
        if let path = ProcessInfo.processInfo.environment["TARS_MEMORY_FIXTURE_OUT"] {
            _ = try store.save(subject: "a Mel", statement: "a Mel é minha gata", correction: false)
            let wire = store.context(for: "Mel", document: try store.load())
            try JSONSerialization.data(withJSONObject: ["xr_memory": wire], options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("PASS: \(count) persistent memory/runtime checks; synthetic facts, no network or hardware")
    }
}
