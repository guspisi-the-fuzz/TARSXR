import Foundation

struct ReconnectionPolicy {
    private(set) var failures = 0
    private(set) var needsIntervention = false
    var delaySeconds: Int { [1, 2, 4, 8, 15, 30][max(0, min(failures - 1, 5))] }
    mutating func failed(authorizationRejected: Bool = false) {
        failures = min(failures + 1, 6)
        needsIntervention = authorizationRejected
    }
    mutating func reset() { failures = 0; needsIntervention = false }
}
