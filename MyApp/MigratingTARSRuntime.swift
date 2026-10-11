import Foundation

/// Explicit migration boundary: weather runs on XR; remaining services keep the validated runtime.
/// Does not instantiate an ESP32 simulator or change the motion/safety transport.
@MainActor final class MigratingTARSRuntime: TARSRuntime {
    private let remaining: any TARSRuntime
    private let weather: NativeWeatherLookup
    init(remaining: any TARSRuntime, weather: NativeWeatherLookup) { self.remaining = remaining; self.weather = weather }
    func hud() async throws -> HUDSnapshot { try await remaining.hud() }
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply { try await remaining.command(action, params: params) }
    func telemetry() async throws -> TARSTelemetry { try await remaining.telemetry() }
    func recover() async throws { try await remaining.recover() }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply { try await remaining.describeImage(png: png, source: source, question: question, history: history) }
    func transcribe(data: Data) async throws -> String { try await remaining.transcribe(data: data) }
    func synthesize(text: String) async throws -> Data { try await remaining.synthesize(text: text) }
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String {
        try Task.checkCancellation()
        if let speech = await weather.answer(text) { try Task.checkCancellation(); return speech }
        return try await remaining.converse(text: text, language: language, context: context)
    }
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws { try await remaining.streamSpeech(text: text, receive: receive) }
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws {
        if let speech = await weather.answer(text) {
            try Task.checkCancellation(); receiveText(speech)
            try await remaining.streamSpeech(text: speech, receive: receive)
        } else { try await remaining.streamConversation(text: text, receive: receive, receiveText: receiveText) }
    }
}
