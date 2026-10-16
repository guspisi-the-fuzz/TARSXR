import Foundation
@main enum VisionDescriptionChecks {
    static func main() {
        typealias Availability = VisionDescriptionAvailability
        func check(_ expected: Availability, active: Bool = true, state: String = "OBSERVING", quality: Bool? = true, captured: Double? = 100, now: Double = 102) {
            precondition(Availability.evaluate(active: active, state: state, qualityAccepted: quality, captured: captured, now: now) == expected)
            if expected != .ready { precondition(!expected.message.isEmpty) }
        }
        check(.ready)
        check(.ready, now: 108)
        check(.inactive, active: false, state: "OFF")
        check(.inactive, active: false, state: "APP_INACTIVE")
        check(.thermal, active: false, state: "THERMAL")
        check(.lowPower, active: false, state: "LOW_POWER")
        check(.cameraUnavailable, active: false, state: "DENIED")
        check(.cameraUnavailable, active: false, state: "UNAVAILABLE")
        check(.waitingFrame, quality: nil, captured: nil)
        check(.rejectedQuality, quality: false, captured: nil)
        check(.rejectedQuality, quality: false) // Never reuse an older good frame.
        check(.stale, now: 108.01)
        check(.stale, now: 99)
        check(.stale, now: .nan)
        check(.stale, captured: .infinity)
        let dark = [UInt8](repeating: 0, count: 64)
        let light = [UInt8](repeating: 255, count: 64)
        var policy = SequentialVisionPolicy()
        precondition(policy.analysisDenial(now: 100, captured: 100, signature: dark) == nil)
        precondition(policy.capture(now: 100))
        precondition(policy.analysisDenial(now: 100, captured: 100, signature: dark) == .busy)
        policy.finish()
        precondition(policy.analysisDenial(now: 100, captured: 100, signature: []) == .invalidFrame)
        precondition(policy.analysisDenial(now: 110, captured: 100, signature: dark) == .stale)
        precondition(policy.analysisDenial(now: .infinity, captured: 100, signature: dark) == .stale)
        precondition(policy.analyze(now: 100, captured: 100, signature: dark))
        // Simultaneous button/voice requests share the same reservation.
        precondition(!policy.analyze(now: 100, captured: 100, signature: dark))
        precondition(policy.calls == 1)
        policy.finish()
        precondition(policy.analysisDenial(now: 129, captured: 129, signature: light) == .cooldown)
        precondition(policy.analysisDenial(now: 130, captured: 130, signature: dark) == .unchanged)
        for (time, signature) in [(130.0, light), (160.0, dark), (190.0, light), (220.0, dark)] {
            precondition(policy.analyze(now: time, captured: time, signature: signature)); policy.finish()
        }
        precondition(policy.analysisDenial(now: 250, captured: 250, signature: light) == .budget)
        precondition(policy.calls == 5)
        print("PASS: visual-description availability and shared admission; off, thermal, permissions, quality, stale frames, overlap, cooldown, unchanged scene and budget; no camera, network or speech")
    }
}
