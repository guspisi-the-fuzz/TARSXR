import Foundation

@main struct ReconnectionPolicyChecks {
    static func main() {
        var p = ReconnectionPolicy()
        for expected in [1, 2, 4, 8, 15, 30, 30, 30] {
            p.failed()
            precondition(p.delaySeconds == expected)
            precondition(!p.needsIntervention)
        }
        p.failed(authorizationRejected: true)
        precondition(p.needsIntervention)
        p.reset()
        precondition(p.failures == 0 && !p.needsIntervention && p.delaySeconds == 1)
        p.failed()
        precondition(p.delaySeconds == 1)
        print("PASS: progressive retry, capped rate, authorization pause, reset and recovery")
    }
}
