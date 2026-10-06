import Foundation

struct TARSCommandParameters: Codable {
    var direction: String? = nil
    var speed: Double? = nil
    var durationMS: Int? = nil
    var degrees: Double? = nil
    var estopGeneration: Int? = nil
    enum CodingKeys: String, CodingKey {
        case direction, speed, degrees
        case durationMS = "duration_ms", estopGeneration = "estop_generation"
    }
}
struct TARSCommand: Codable {
    let intent: String
    let action: String
    let params: TARSCommandParameters
}
struct TARSCommandReply: Decodable { let status: String; let reason: String; let telemetry: TARSTelemetry? }
struct TARSRecoveryReply: Decodable { let recovered: Bool; let state: String }
struct TARSTelemetry: Decodable {
    let motionActive: Bool
    let emergencyStop: Bool
    let estopGeneration: Int
    let recoveryRequired: Bool
    let panDeg: Double
    enum CodingKeys: String, CodingKey {
        case motionActive = "motion_active", emergencyStop = "emergency_stop"
        case estopGeneration = "estop_generation", recoveryRequired = "recovery_required"
        case panDeg = "pan_deg"
    }
}
struct TARSAPIResponse<T: Decodable>: Decodable { let ok: Bool; let data: T? }
struct SpeechReply: Decodable { let audio: String; let format: String }
struct TranscriptionReply: Decodable { let text: String }
struct VisionReply: Decodable {
    let description: String
    let source: String
    let live_camera: Bool
    let actions_enabled: Bool
    let metric_geometry_available: Bool
}
struct ConversationReply: Decodable { let speech: String }

enum TARSClientError: LocalizedError {
    case unavailable, unauthorized, pairingRejected, ai(String), rejected(String)
    var blocksAutomaticVoice: Bool {
        switch self {
        case .pairingRejected: return true
        case .ai(let code):
            return ["AI_INSUFFICIENT_QUOTA", "AI_QUOTA_OR_RATE_LIMIT", "AI_AUTH_FAILED",
                    "AI_ACCESS_DENIED", "AI_LOCAL_LIMIT", "AI_UNCONFIGURED"].contains(code)
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "O Core não respondeu. Confira a conexão."
        case .unauthorized: return "Sessão expirada. A conexão será refeita automaticamente."
        case .pairingRejected: return "Autorização recusada. Confira o pareamento com o Core."
        case .rejected(let reason): return "Comando bloqueado: \(reason)"
        case .ai(let code):
            switch code {
            case "AI_INSUFFICIENT_QUOTA": return "A API precisa de saldo ou liberação de cota."
            case "AI_RATE_LIMIT": return "Limite temporário da API. Aguarde e tente novamente."
            case "AI_QUOTA_OR_RATE_LIMIT": return "A API está sem saldo ou no limite de uso."
            case "AI_LOCAL_LIMIT": return "Limite de testes desta sessão atingido."
            case "AI_AUTH_FAILED", "AI_ACCESS_DENIED": return "A API não autorizou esta conexão."
            case "VISION_REQUEST_TIMEOUT": return "A análise demorou demais. A foto continua disponível para outra pergunta."
            case "STALE_VISION_FRAME": return "O pedido de análise expirou. A foto pode ser usada em uma nova pergunta."
            case "INVALID_IMAGE": return "Não consegui usar essa imagem. Escolha outra foto."
            case "VISION_FRAME_CONFLICT", "INVALID_VISION_SCHEMA", "INVALID_VISION_REQUEST", "INVALID_VISION_FRAME", "INVALID_VISION_TIME": return "A imagem não pôde ser enviada. Selecione novamente."
            case "AI_BUSY": return "A IA está respondendo. Tente novamente em instantes."
            case "AI_UNCONFIGURED": return "A IA ainda não está configurada neste Core."
            default: return "A IA está indisponível no momento. Tente novamente."
            }
        }
    }
}

/// The operations the XR uses, independent of HTTP, pairing or a remote Core.
/// The production implementation remains remote until an embedded runtime is validated.
@MainActor
protocol TARSRuntime: AnyObject {
    func hud() async throws -> HUDSnapshot
    func command(_ action: String, params: TARSCommandParameters?) async throws -> TARSCommandReply
    func telemetry() async throws -> TARSTelemetry
    func recover() async throws
    func describeImage(png: Data, source: String, question: String, history: [[String: String]]) async throws -> VisionReply
    func transcribe(data: Data) async throws -> String
    func synthesize(text: String) async throws -> Data
    func converse(text: String, language: String, context: [String: Any]?) async throws -> String
    func streamSpeech(text: String, receive: @escaping @MainActor (Data) throws -> Void) async throws
    func streamConversation(text: String, receive: @escaping @MainActor (Data) throws -> Void, receiveText: @escaping @MainActor (String) -> Void) async throws
}

extension TARSRuntime {
    func command(_ action: String) async throws -> TARSCommandReply {
        try await command(action, params: nil)
    }
}
