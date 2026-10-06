import Foundation

@MainActor
private final class RecordingRemoteClient: TARSRemoteClient {
    var token: String?
    var calls: [String] = []
    var failure: Error?
    var rejectPair = false
    var expireOnOperation = false
    var cancelAfterPair = false
    var hudData = Data()
    var lastParams: TARSCommandParameters?
    var lastContext: [String: Any]?
    var lastLanguage = ""
    var lastText = ""
    var lastImage = Data()
    var lastSource = ""
    var lastHistory: [[String: String]] = []
    var lastRecording = Data()

    func pair(secret: String) async throws {
        calls.append("pair")
        precondition(secret == "fixture-secret")
        if rejectPair { throw TARSClientError.pairingRejected }
        token = "fixture-token"
        if cancelAfterPair { withUnsafeCurrentTask { $0?.cancel() } }
    }
    private func operation(_ name: String) throws {
        calls.append(name)
        if expireOnOperation { token = nil; throw TARSClientError.unauthorized }
        if let failure { throw failure }
    }
    func request(path: String, method: String, body: Data?) async throws -> Data {
        precondition(path == "v1/hud" && method == "GET" && body == nil)
        try operation("hud")
        return hudData
    }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply {
        lastParams = params
        try operation(action)
        return TARSCommandReply(status: "accepted", reason: "fixture", telemetry: fixtureTelemetry())
    }
    func telemetry() async throws -> TARSTelemetry {
        try operation("telemetry")
        return fixtureTelemetry()
    }
    func recover() async throws { try operation("recover") }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply {
        lastImage = png; lastSource = source; lastText = question; lastHistory = history
        try operation("vision")
        return VisionReply(description: "reference", source: source, live_camera: false, actions_enabled: false, metric_geometry_available: false)
    }
    func transcribe(data: Data) async throws -> String {
        lastRecording = data
        try operation("transcribe")
        return "fala de teste"
    }
    func synthesize(text: String) async throws -> Data {
        lastText = text
        try operation("synthesize")
        return Data([1, 2, 3])
    }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        lastText = text; lastLanguage = language; lastContext = context
        try operation("converse")
        return "resposta de teste"
    }
    func streamSpeech(text: String, conversation: Bool, receiveText: @escaping @MainActor (String) -> Void, receive: @escaping @MainActor (Data) throws -> Void) async throws {
        lastText = text
        try operation(conversation ? "conversation-stream" : "speech-stream")
        if conversation { receiveText("resposta em fluxo") }
        try receive(Data([1, 0, 2, 0]))
    }
    private func fixtureTelemetry() -> TARSTelemetry {
        TARSTelemetry(motionActive: false, emergencyStop: true, estopGeneration: 7, recoveryRequired: true, panDeg: 12)
    }
}

@main
struct RemoteRuntimeChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            count += 1
        }
        let client = RecordingRemoteClient()
        let runtime: any TARSRuntime = RemoteTARSRuntime(client: client, pairingSecret: "fixture-secret")
        let snapshot = HUDSnapshot(schemaVersion: "1.0", timestamp: 1, identity: [:], cognition: [:],
            system: ["esp32": "UNAVAILABLE", "safety": "STOP"], sensors: [:], resources: [:], motion: ["active": .bool(false)])
        struct Envelope: Encodable { let ok: Bool; let data: HUDSnapshot }
        client.hudData = try JSONEncoder().encode(Envelope(ok: true, data: snapshot))
        let hud = try await runtime.hud()
        check(client.calls == ["pair", "hud"], "First HUD pairs exactly once")
        check(hud.system["esp32"] == "UNAVAILABLE" && hud.system["safety"] == "STOP", "Unavailable hardware is not replaced by a healthy mock")
        _ = try await runtime.hud()
        check(client.calls == ["pair", "hud", "hud"], "Existing session is reused")
        client.hudData = try JSONEncoder().encode(Envelope(ok: false, data: snapshot))
        do { _ = try await runtime.hud(); preconditionFailure("ok=false was accepted") }
        catch TARSClientError.unavailable { count += 1 }
        client.hudData = Data("{}".utf8)
        do { _ = try await runtime.hud(); preconditionFailure("Malformed HUD was accepted") }
        catch is DecodingError { count += 1 }
        client.hudData = try JSONEncoder().encode(Envelope(ok: true, data: snapshot))

        _ = try await runtime.command("MOVE", params: .init(direction: "FORWARD", speed: 0.2, durationMS: 250))
        check(client.lastParams?.direction == "FORWARD" && client.lastParams?.durationMS == 250 && client.lastParams?.speed == 0.2, "Motion parameters preserved")
        _ = try await runtime.command("CLEAR_ESTOP", params: .init(estopGeneration: 7))
        check(client.lastParams?.estopGeneration == 7, "E-stop generation preserved")
        _ = try await runtime.command("STOP")
        check(client.lastParams == nil && client.calls.last == "STOP", "Parameterless STOP preserved")
        let t = try await runtime.telemetry()
        check(t.emergencyStop && t.recoveryRequired && !t.motionActive, "Safety telemetry preserved")
        let beforeRecovery = client.calls.count
        try await runtime.recover()
        check(Array(client.calls.dropFirst(beforeRecovery)) == ["recover"], "Recovery neither clears E-stop nor moves automatically")
        let response = try await runtime.converse(text: "estado", language: "pt-BR", context: ["internal_wake_summary": true])
        check(response == "resposta de teste" && client.lastContext?["internal_wake_summary"] as? Bool == true && client.lastLanguage == "pt-BR" && client.lastText == "estado", "Conversation context and language preserved")
        _ = try await runtime.converse(text: "oi", language: "auto", context: nil)
        check(client.lastContext == nil && client.lastLanguage == "auto", "No invented conversation context")
        let recording = Data([8, 9])
        let transcript = try await runtime.transcribe(data: recording)
        check(transcript == "fala de teste" && client.lastRecording == recording, "Transcription forwarded")
        let speech = try await runtime.synthesize(text: "olá")
        check(speech == Data([1, 2, 3]) && client.lastText == "olá", "Synthesis forwarded")
        let history = [["role": "user", "content": "anterior"]]
        let vision = try await runtime.describeImage(png: recording, source: "reference", question: "o que é?", history: history)
        check(client.lastImage == recording && client.lastSource == "reference" && client.lastHistory == history && client.lastText == "o que é?", "Vision arguments preserved")
        check(!vision.live_camera && !vision.actions_enabled && !vision.metric_geometry_available, "Vision limits preserved")
        var audio = Data(); var text = ""
        try await runtime.streamSpeech(text: "fala", receive: { audio.append($0) })
        check(client.calls.last == "speech-stream" && audio == Data([1, 0, 2, 0]), "Speech streaming retains audio callbacks")
        audio.removeAll()
        try await runtime.streamConversation(text: "pergunta", receive: { audio.append($0) }, receiveText: { text += $0 })
        check(client.calls.last == "conversation-stream" && text == "resposta em fluxo" && audio == Data([1, 0, 2, 0]), "Conversation streaming retains text and audio")
        enum ConsumerError: Error { case stopped }
        do {
            try await runtime.streamSpeech(text: "stop", receive: { _ in throw ConsumerError.stopped })
            preconditionFailure("Consumer failure swallowed")
        } catch ConsumerError.stopped { count += 1 }
        check(client.calls.filter { $0 == "pair" }.count == 1, "All operations reuse one session")

        client.failure = TARSClientError.rejected("SAFETY_STOP_LATCHED")
        var before = client.calls.count
        do { _ = try await runtime.command("MOVE"); preconditionFailure("Safety rejection swallowed") }
        catch TARSClientError.rejected(let reason) { check(reason == "SAFETY_STOP_LATCHED", "Exact safety rejection preserved") }
        check(Array(client.calls.dropFirst(before)) == ["MOVE"], "Rejected MOVE is never repeated")
        client.failure = TARSClientError.unavailable
        before = client.calls.count
        do { try await runtime.recover(); preconditionFailure("Recovery failure swallowed") }
        catch TARSClientError.unavailable { count += 1 }
        check(Array(client.calls.dropFirst(before)) == ["recover"], "Recovery is never repeated")
        client.failure = TARSClientError.ai("AI_LOCAL_LIMIT")
        do { _ = try await runtime.converse(text: "x", language: "auto", context: nil); preconditionFailure("AI failure swallowed") }
        catch let error as TARSClientError { check(error.blocksAutomaticVoice, "AI failure remains blocking") }
        client.failure = nil
        client.expireOnOperation = true
        before = client.calls.count
        do { _ = try await runtime.command("MOVE"); preconditionFailure("Expired session accepted") }
        catch TARSClientError.unauthorized { count += 1 }
        check(Array(client.calls.dropFirst(before)) == ["MOVE"], "401 does not pair/replay motion inside the operation")
        client.expireOnOperation = false
        before = client.calls.count
        _ = try await runtime.hud()
        check(Array(client.calls.dropFirst(before)) == ["pair", "hud"], "A new explicit HUD call can re-pair")

        let rejected = RecordingRemoteClient(); rejected.rejectPair = true
        let blocked: any TARSRuntime = RemoteTARSRuntime(client: rejected, pairingSecret: "fixture-secret")
        do { _ = try await blocked.command("MOVE"); preconditionFailure("Pair rejection accepted") }
        catch TARSClientError.pairingRejected { count += 1 }
        check(rejected.calls == ["pair"], "Rejected pairing sends no command")
        before = client.calls.count
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await runtime.command("MOVE"); preconditionFailure("Cancelled MOVE sent") }
            catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
        }.value
        check(client.calls.count == before, "Cancellation prevents sending even with an existing session")
        let cancelPair = RecordingRemoteClient(); cancelPair.cancelAfterPair = true
        let cancelled: any TARSRuntime = RemoteTARSRuntime(client: cancelPair, pairingSecret: "fixture-secret")
        await Task { @MainActor in
            do { _ = try await cancelled.command("MOVE"); preconditionFailure("Command sent after cancellation during pairing") }
            catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
        }.value
        check(cancelPair.calls == ["pair"], "Cancellation during pairing never sends the waiting command")
        print("PASS: \(count) remote runtime checks (injected transport; no network or hardware)")
    }
}
