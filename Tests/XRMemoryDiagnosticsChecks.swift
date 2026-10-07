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
struct XRMemoryDiagnosticsChecks {
    @MainActor static func main() async throws {
        #if !DEBUG
        preconditionFailure("This diagnostic test must compile with -DDEBUG")
        #else
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("memory-trace-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("Library/Application Support/TARSMemory/memory-v1.json")
        let store = XRPersistentMemory(url: file, now: { 1791310000 })
        check(store.diagnosticMetadata()["file_node"] as? String == "missing", "missing node observed")
        check(store.diagnosticMetadata()["parent_node"] as? String == "missing", "missing parent observed")
        check(store.diagnosticMetadata()["path_matches_device_contract"] as? Bool == true, "actual path contract")
        check(!fm.fileExists(atPath: file.path), "diagnostics never create memory")
        var opened = 0
        let remote = MemoryFixtureRuntime()
        let runtime = MemoryTARSRuntime(underlying: remote, memory: { opened += 1; return store })
        check(opened == 0, "startup marker does not initialize storage")
        var events: [[String: Any]] = []
        runtime.memoryTraceObserver = { events.append($0) }
        _ = try await runtime.converse(text: "quem é a Mel?", language: "pt-BR", context: nil)
        check(opened == 1, "actual request reaches storage")
        check(!fm.fileExists(atPath: file.path), "query alone creates no file")
        check(events.contains { $0["event"] as? String == "recall_lookup" && $0["found"] as? Bool == false }, "lookup miss traced")
        check(events.contains { $0["event"] as? String == "remote_request" }, "unknown general question delegated")
        check(events.contains { $0["file_node"] as? String == "missing" }, "runtime sees actual missing file")
        let statement = "a Mel é minha gata"
        let reply = try await runtime.converse(text: "guarde que " + statement, language: "pt-BR", context: nil)
        check(reply == "Salvei neste XR: " + statement + ".", "same local save reply")
        check(fm.fileExists(atPath: file.path), "actual save creates file")
        check(events.contains { $0["event"] as? String == "save_verified" && $0["file_node"] as? String == "file" }, "verified write traced after readback")
        check(events.contains { $0["intent"] as? String == "save" && $0["mel_subject_match"] as? Bool == true }, "recognized named test entity")
        let before = try Data(contentsOf: file)
        _ = store.diagnosticMetadata()
        check(try Data(contentsOf: file) == before, "metadata cannot alter saved facts")
        let reopened = MemoryTARSRuntime(underlying: remote, memory: { XRPersistentMemory(url: file) })
        reopened.memoryTraceObserver = { events.append($0) }
        let readReply = try await reopened.converse(text: "quem é a Mel?", language: "pt-BR", context: nil)
        check(readReply == "A Mel é sua gata.", "fresh runtime reads existing fact")
        check(events.last?["event"] as? String == "recall_lookup", "local recall does not reach remote")
        check(events.last?["found"] as? Bool == true, "existing fact traced as found")
        check(events.last?["fact_count"] as? Int == 1, "count metadata without text")
        let serial = String(data: try JSONSerialization.data(withJSONObject: events), encoding: .utf8)!
        for forbidden in [statement, "minha gata", "Salvei", "ownerID", "statement", "subject\":"] {
            check(!serial.contains(forbidden), "no private field: \(forbidden)")
        }
        let calls = remote.calls.count
        _ = try await reopened.converse(text: "guarde que a Mel é minha cachorra", language: "pt-BR", context: nil)
        check(events.last?["code"] as? String == "MEMORY_CHANGED", "existing correction rule preserved")
        check(remote.calls.count == calls, "memory conflict not delegated")
        check(try Data(contentsOf: file) == before, "diagnostic preserves conflict data")
        let failedPath = root.appendingPathComponent("failed/memory.json")
        let failedStore = XRPersistentMemory(url: failedPath, writer: { _, _ in throw XRMemoryError.unavailable })
        let failed = MemoryTARSRuntime(underlying: remote, memory: { failedStore })
        var failedEvents: [[String: Any]] = []
        failed.memoryTraceObserver = { failedEvents.append($0) }
        let failedReply = try await failed.converse(text: "guarde que a Mel é minha gata", language: "pt-BR", context: nil)
        check(!failedReply.hasPrefix("Salvei"), "failed save not confirmed")
        check(failedEvents.last?["code"] as? String == "STORAGE_UNAVAILABLE", "write failure identified")
        check(!failedEvents.contains { $0["event"] as? String == "save_verified" }, "no success trace for failed save")
        check(!fm.fileExists(atPath: failedPath.path), "failed writer does not create file")
        let unavailable = MemoryTARSRuntime(underlying: remote, memory: { throw XRMemoryError.unavailable })
        var unavailableEvents: [[String: Any]] = []
        unavailable.memoryTraceObserver = { unavailableEvents.append($0) }
        _ = try await unavailable.converse(text: "quem é a Mel?", language: "pt-BR", context: nil)
        check(unavailableEvents.last?["event"] as? String == "store_open_failed", "factory failure distinct from lookup")
        let log = root.appendingPathComponent("memory-trace.json")
        var console: [String] = []
        let trace = XRMemoryTrace(destination: log, now: { 1791310000 }, echo: { console.append($0) })
        trace.record("runtime_ready")
        check(trace.lastWriteSucceeded, "marker stored even before a memory write")
        var report = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
        check(report["version"] as? String == XRMemoryTrace.marker, "build marker written")
        let initial = (report["events"] as! [[String: Any]]).first!
        check(initial["event"] as? String == "runtime_ready", "initial runtime marker")
        check(!console[0].contains("statement"), "startup trace has no memory contents")
        for _ in 0..<70 { trace.record("intent_received", fields: ["intent": "save", "statement": "SENTINEL_PRIVATE", "subject": "SENTINEL_NAME", "token": "SENTINEL_TOKEN"]) }
        report = try JSONSerialization.jsonObject(with: Data(contentsOf: log)) as! [String: Any]
        let ring = report["events"] as! [[String: Any]]
        check(ring.count == 24, "bounded diagnostic history")
        check(ring.last?["sequence"] as? Int == 71, "latest sequence preserved")
        let raw = String(data: try Data(contentsOf: log), encoding: .utf8)!
        check(!raw.contains("SENTINEL"), "disk trace drops unknown fields")
        check(!console.joined().contains("SENTINEL"), "console trace drops unknown fields")
        trace.record("SENTINEL_EVENT", fields: ["intent": "SENTINEL_INTENT", "code": "SENTINEL_CODE"], storage: ["file_node": "SENTINEL_PATH"])
        check(!String(data: try Data(contentsOf: log), encoding: .utf8)!.contains("SENTINEL"), "trace rejects arbitrary metadata strings")
        let brokenLog = XRMemoryTrace(destination: root, echo: { _ in })
        brokenLog.record("runtime_ready")
        check(!brokenLog.lastWriteSucceeded, "trace write failure reported without throwing")
        check(try Data(contentsOf: file) == before, "logging never touches memory")
        let help = XRMemoryTrace.intentMetadata(.help)
        check(help["intent"] as? String == "help", "grammar help traced")
        check(XRMemoryTrace.intentMetadata(.ordinary)["intent"] as? String == "ordinary", "unrecognized command traced")
        _ = try await reopened.converse(text: "esqueça a Mel", language: "pt-BR", context: nil)
        check(events.last?["event"] as? String == "forget_verified", "deletion traced")
        check(try XRPersistentMemory(url: file).load().facts.isEmpty, "normal deletion preserved")
        print("PASS: \(count) memory trace checks; no network or device")
        #endif
    }
}
