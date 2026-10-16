import Foundation

/// Heuristic image-quality gate, never an object detector or navigation sensor.
struct FrameQuality: Sendable {
    enum Status: String, Sendable {
        case ready = "READY"
        case dark = "TOO_DARK"
        case bright = "TOO_BRIGHT"
        case lowDetail = "BLUR_OR_LOW_DETAIL"
        case invalid = "INVALID"
    }
    let status: Status
    let luminance: Double
    let sharpness: Double
    var accepted: Bool { status == .ready }
    var message: String {
        switch status {
        case .ready: return "Qualidade suficiente para tentar descrever."
        case .dark: return "Pouca luz. Aguardando outro quadro; nenhuma imagem enviada."
        case .bright: return "Imagem muito clara. Aguardando outro quadro; nenhuma imagem enviada."
        case .lowDetail: return "Pouco detalhe ou possível borrão. Estabilize a câmera; aguardando outro quadro."
        case .invalid: return "Não foi possível avaliar a qualidade do quadro."
        }
    }
    /// Initial thresholds require calibration on the physical XR. Flat walls can
    /// look like blur; noise can look sharp. These scores do not establish truth.
    static func measure(_ pixels: [UInt8], width: Int, height: Int,
                        minimumSharpness: Double = 60) -> FrameQuality {
        guard (3...256).contains(width), (3...256).contains(height), pixels.count == width * height,
              minimumSharpness.isFinite, minimumSharpness >= 0 else {
            return FrameQuality(status: .invalid, luminance: 0, sharpness: 0)
        }
        let luminance = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let laplacian = Double(Int(pixels[i-1]) + Int(pixels[i+1]) + Int(pixels[i-width]) + Int(pixels[i+width]) - 4 * Int(pixels[i]))
                sum += laplacian; squares += laplacian * laplacian; count += 1
            }
        }
        let sharpness = max(0, squares / count - pow(sum / count, 2))
        let status: Status = luminance < 25 ? .dark : luminance > 240 ? .bright : sharpness < minimumSharpness ? .lowDetail : .ready
        return FrameQuality(status: status, luminance: luminance, sharpness: sharpness)
    }
}
