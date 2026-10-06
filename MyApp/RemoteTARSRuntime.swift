import Foundation

/// Existing HTTP client surface; kept private to the remote adapter and its tests.
/// An embedded runtime implements TARSRuntime, not this transport protocol.
@MainActor
protocol TARSRemoteClient: AnyObject {
    var token: String? { get }
    func pair(secret: String) async throws
    func request(path: String, method: String, body: Data?) async throws -> Data
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply
    func telemetry() async throws -> TARSTelemetry
    func recover() async throws
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply
    func transcribe(data: Data) async throws -> String
    func synthesize(text: String) async throws -> Data
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String
    func streamSpeech(text: String, conversation: Bool, receiveText: @escaping @MainActor (String) -> Void, receive: @escaping @MainActor (Data) throws -> Void) async throws
}

/// Preserves the existing Core connection. No automatic replay of failed operations.
@MainActor
final class RemoteTARSRuntime: TARSRuntime {
    private let client: any TARSRemoteClient
    private let pairingSecret: String

    init(client: any TARSRemoteClient, pairingSecret: String) {
        self.client = client
        self.pairingSecret = pairingSecret
    }

    private func ensureSession() async throws {
        try Task.checkCancellation()
        if client.token == nil { try await client.pair(secret: pairingSecret) }
        try Task.checkCancellation()
    }

    func hud() async throws -> HUDSnapshot {
        try await ensureSession()
        let data = try await client.request(path: "v1/hud", method: "GET", body: nil)
        try Task.checkCancellation()
        let envelope = try JSONDecoder().decode(RemoteHUDEnvelope.self, from: data)
        guard envelope.ok else { throw TARSClientError.unavailable }
        return envelope.data
    }

    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply {
        try await ensureSession()
        return try await client.command(action, params: params)
    }

    func telemetry() async throws -> TARSTelemetry {
        try await ensureSession()
        return try await client.telemetry()
    }

    func recover() async throws {
        try await ensureSession()
        try await client.recover()
    }

    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply {
        try await ensureSession()
        return try await client.describeImage(png: png, source: source, question: question, history: history)
    }

    func transcribe(data: Data) async throws -> String {
        try await ensureSession()
        return try await client.transcribe(data: data)
    }

    func synthesize(text: String) async throws -> Data {
        try await ensureSession()
        return try await client.synthesize(text: text)
    }

    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        try await ensureSession()
        return try await client.converse(text: text, language: language, context: context)
    }

    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws {
        try await ensureSession()
        try await client.streamSpeech(text: text, conversation: false, receiveText: { _ in }, receive: receive)
    }

    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws {
        try await ensureSession()
        try await client.streamSpeech(text: text, conversation: true, receiveText: receiveText, receive: receive)
    }
}

private struct RemoteHUDEnvelope: Decodable {
    let ok: Bool
    let data: HUDSnapshot
}
