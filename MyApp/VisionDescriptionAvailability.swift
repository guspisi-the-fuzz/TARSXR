import Foundation

/// Read-only admission: never activates a camera or changes motion/safety.
enum VisionDescriptionAvailability: Equatable, Sendable {
    case ready, inactive, thermal, lowPower, cameraUnavailable, waitingFrame, rejectedQuality, stale
    static func evaluate(active: Bool, state: String, qualityAccepted: Bool?, captured: Double?, now: Double) -> Self {
        if !active {
            switch state {
            case "THERMAL": return .thermal
            case "LOW_POWER": return .lowPower
            case "DENIED", "UNAVAILABLE": return .cameraUnavailable
            default: return .inactive
            }
        }
        if qualityAccepted == false { return .rejectedQuality }
        guard qualityAccepted == true, let captured else { return .waitingFrame }
        guard now.isFinite, captured.isFinite, now >= captured, now - captured <= 8 else { return .stale }
        return .ready
    }
    var message: String {
        switch self {
        case .ready: return ""
        case .inactive: return "A visão local está desligada. Ative a visão para eu descrever um quadro recente."
        case .thermal: return "A visão está pausada pela temperatura do XR. Aguarde esfriar e ative novamente."
        case .lowPower: return "A visão está pausada porque o modo de economia de energia está ativo."
        case .cameraUnavailable: return "A câmera está indisponível ou sem permissão. Confira o estado da câmera no app."
        case .waitingFrame: return "Ainda não tenho um quadro aprovado. Aguarde a próxima amostra da câmera."
        case .rejectedQuality: return "O quadro atual não passou no filtro de qualidade. Estabilize a câmera e confira a iluminação."
        case .stale: return "O último quadro está antigo. Aguarde uma nova imagem antes de pedir a descrição."
        }
    }
}
