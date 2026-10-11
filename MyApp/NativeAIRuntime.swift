import Foundation

/// Native cognition/audio/vision. The body link stays isolated and never supplies AI services.
@MainActor final class NativeAIRuntime: TARSRuntime {
    static let service = NativeAIService {
        let config = try NativeAIKeychain.load(); return (config.key,config.model)
    }
    private let body: NativeBodyCore
    private let ai: NativeAIService
    private let lookup = NativePublicLookup()
    init(body: any TARSRuntime, ai: NativeAIService) { self.body=NativeBodyCore(bridge:body); self.ai=ai }
    func hud() async throws -> HUDSnapshot {
        let remote = try? await body.hud()
        try Task.checkCancellation()
        var system = remote?.system ?? ["esp32":"UNAVAILABLE","safety":"UNKNOWN","autonomy":"BODY_DISCONNECTED","forward":"UNAVAILABLE","reverse":"UNAVAILABLE"]
        system["core"]="XR_NATIVE"; system["supervisor"]="UNMONITORED"; system["audio"]="XR_NATIVE"; system["vision"]="REFERENCE"
        return HUDSnapshot(schemaVersion:"1.0", timestamp:Date().timeIntervalSince1970, identity:["name":"TARS","role":"AUTONOMOUS SYSTEM"], cognition:["voice_state":"IDLE","ai":(try? NativeAIKeychain.load()) == nil ? "UNCONFIGURED" : "CONFIGURED"], system:system, sensors:remote?.sensors ?? [:], resources:remote?.resources ?? [:], motion:remote?.motion ?? [:])
    }
    func command(_ action:String, params:TARSCommandParameters?) async throws -> TARSCommandReply { try await body.command(action,params:params) }
    func telemetry() async throws -> TARSTelemetry { try await body.telemetry() }
    func recover() async throws { try await body.recover() }
    func transcribe(data:Data) async throws -> String { try await ai.transcribe(data) }
    func synthesize(text:String) async throws -> Data { try await ai.synthesize(text) }
    func streamSpeech(text:String,receive:@escaping @MainActor (Data) throws -> Void) async throws { try await ai.streamSpeech(text,receive:receive) }
    func describeImage(png:Data,source:String,question:String,history:[[String:String]]) async throws -> VisionReply { try await ai.describe(png:png,source:source,question:question,history:history) }
    func converse(text:String,language:String,context:[String:Any]?) async throws -> String {
        let normalized = NativeWeatherLookup.normalize(SpokenRequest.clean(text))
        if NativeWeatherLookup.matches(normalized, #"\b(esp32|movimentar|movimento|mover|andar|move|forward|backward)\b"#) {
            let snapshot = try await hud()
            let virtual = snapshot.system["esp32"] == "VIRTUAL"
            let clear = snapshot.system["safety"] == "CLEAR"
            let status = virtual ? "O ESP32 está virtual; os movimentos são simulados." : "Não há ESP32 virtual confirmado neste momento."
            let safety = clear ? "A segurança está liberada no estado consultado." : "O movimento está bloqueado; é necessária recuperação explícita e verificação de segurança."
            return status + " " + safety + " O controle implementado inclui avançar, recuar, parar, parada de emergência, direção e posição da cabeça. Esta consulta não executou movimento nem liberou a segurança."
        }
        if let result=await lookup.answer(text) { return result }
        if context?["internal_wake_summary"] as? Bool == true {
            return language.hasPrefix("en") ? "I'm awake. How can I help?" : "Estou aqui. Como posso ajudar?"
        }
        return try await ai.converse(text,context:context)
    }
    func streamConversation(text:String,receive:@escaping @MainActor (Data) throws -> Void,receiveText:@escaping @MainActor (String) -> Void) async throws {
        let speech=try await converse(text:text,language:"auto",context:nil)
        receiveText(speech); try await ai.streamSpeech(speech,receive:receive)
    }
}
