import Foundation

/// Deterministic admission policy, independent of camera, network and movement.
struct SequentialVisionPolicy {
    private(set) var busy = false
    private(set) var calls = 0
    private var captureTime: TimeInterval?
    private var analysisTime: TimeInterval?
    private var analyzed: [UInt8]?
    mutating func capture(now: TimeInterval) -> Bool {
        guard !busy, captureTime.map({ now - $0 >= 3 }) ?? true else { return false }
        busy = true; captureTime = now; return true
    }
    mutating func finish() { busy = false }
    enum AnalysisDenial: String, Sendable {
        case busy, invalidFrame, stale, budget, cooldown, unchanged
        var message: String {
            switch self {
            case .busy: return "Já estou capturando ou analisando uma imagem. Aguarde a conclusão."
            case .invalidFrame: return "Não tenho um quadro válido para analisar."
            case .stale: return "O último quadro está antigo. Aguarde uma nova imagem."
            case .budget: return "Atingi o limite de cinco tentativas de descrição nesta execução do app."
            case .cooldown: return "Aguarde pelo menos trinta segundos entre as análises visuais."
            case .unchanged: return "A cena não mudou o suficiente desde a última análise; não enviei outra imagem à IA."
            }
        }
    }
    func analysisDenial(now: TimeInterval, captured: TimeInterval, signature: [UInt8]) -> AnalysisDenial? {
        if busy { return .busy }
        guard signature.count == 64 else { return .invalidFrame }
        guard now.isFinite, captured.isFinite, now >= captured, now - captured <= 8 else { return .stale }
        if calls >= 5 { return .budget }
        if let analysisTime, now - analysisTime < 30 { return .cooldown }
        if let analyzed, zip(signature, analyzed).reduce(0, { $0 + abs(Int($1.0) - Int($1.1)) }) < 768 { return .unchanged }
        return nil
    }
    func eligible(now: TimeInterval, captured: TimeInterval, signature: [UInt8]) -> Bool {
        analysisDenial(now: now, captured: captured, signature: signature) == nil
    }
    mutating func analyze(now: TimeInterval, captured: TimeInterval, signature: [UInt8]) -> Bool {
        guard eligible(now: now, captured: captured, signature: signature) else { return false }
        busy = true; calls += 1; analysisTime = now; analyzed = signature; return true
    }
}
