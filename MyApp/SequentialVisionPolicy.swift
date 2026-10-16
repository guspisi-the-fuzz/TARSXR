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
    func eligible(now: TimeInterval, captured: TimeInterval, signature: [UInt8]) -> Bool {
        guard !busy, signature.count == 64, now >= captured, now - captured <= 8, calls < 5,
              analysisTime.map({ now - $0 >= 30 }) ?? true else { return false }
        guard let analyzed else { return true }
        return zip(signature, analyzed).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } >= 768
    }
    mutating func analyze(now: TimeInterval, captured: TimeInterval, signature: [UInt8]) -> Bool {
        guard eligible(now: now, captured: captured, signature: signature) else { return false }
        busy = true; calls += 1; analysisTime = now; analyzed = signature; return true
    }
}
