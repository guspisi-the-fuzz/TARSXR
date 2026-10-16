import Foundation
@main enum SequentialVisionChecks {
    static func main() {
        var p = SequentialVisionPolicy()
        let dark = [UInt8](repeating: 0, count: 64)
        let light = [UInt8](repeating: 255, count: 64)
        precondition(p.capture(now: 0))
        precondition(!p.capture(now: 3)) // outstanding capture, drop rather than queue
        precondition(!p.analyze(now: 0, captured: 0, signature: dark))
        p.finish()
        precondition(!p.capture(now: 2.99))
        precondition(p.capture(now: 3)); p.finish()
        precondition(!p.eligible(now: 12, captured: 3, signature: dark))
        precondition(!p.eligible(now: 2, captured: 3, signature: dark))
        precondition(!p.eligible(now: 3, captured: 3, signature: []))
        precondition(p.analyze(now: 3, captured: 3, signature: dark))
        precondition(!p.capture(now: 6)) // outstanding network request
        p.finish()
        precondition(!p.eligible(now: 32, captured: 32, signature: light))
        precondition(!p.eligible(now: 33, captured: 33, signature: dark))
        precondition(!p.eligible(now: 33, captured: 33, signature: [UInt8](repeating: 11, count: 64)))
        precondition(p.analyze(now: 33, captured: 33, signature: light)); p.finish()
        for (time, signature) in [(63.0, dark), (93.0, light), (123.0, dark)] {
            precondition(p.analyze(now: time, captured: time, signature: signature)); p.finish()
        }
        precondition(p.calls == 5)
        precondition(!p.analyze(now: 153, captured: 153, signature: light))
        print("PASS: simulated frames, cadence, duplicate/in-flight rejection, age, change threshold, API cooldown and budget")
    }
}
