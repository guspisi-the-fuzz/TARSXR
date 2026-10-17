import Foundation

/// Admission for read-only HUD polling, separate from actuator/safety admission.
struct NativeBodyObservationPolicy: Sendable {
    private(set) var failures=0
    private(set) var nextAttempt=0.0
    private(set) var inFlight=false
    mutating func begin(now: Double) -> Bool {
        guard now.isFinite, now>=0, !inFlight, now>=nextAttempt else { return false }
        inFlight=true; return true
    }
    mutating func succeeded(now: Double) {
        inFlight=false; failures=0; nextAttempt=now+0.5
    }
    mutating func failed(now: Double) {
        inFlight=false; failures=min(6,failures+1)
        nextAttempt=now+Double([1,2,4,8,15,30][failures-1])
    }
    mutating func cancelled(now: Double) { inFlight=false; nextAttempt=now+0.5 }
}

/// Returns no old telemetry on failure. Does not wrap command(), recover() or STOP.
@MainActor final class NativeBodyObservation {
    private let now: @MainActor () -> Double
    private let fetch: @MainActor () async throws -> HUDSnapshot
    private(set) var policy=NativeBodyObservationPolicy()
    private var generation=UUID()
    private var cached: (snapshot: HUDSnapshot,receivedAt: Double)?
    init(now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },fetch: @escaping @MainActor () async throws -> HUDSnapshot) {
        self.now=now; self.fetch=fetch
    }
    var retryInSeconds: Int {
        let t=now(); guard t.isFinite else { return 0 }
        return Int(ceil(min(30,max(0,policy.nextAttempt-t))))
    }
    func invalidate() { generation=UUID(); cached=nil }
    func read() async -> HUDSnapshot? {
        let t=now()
        guard !Task.isCancelled, policy.begin(now:t) else {
            if !Task.isCancelled, let cached, t.isFinite, t>=cached.receivedAt, t-cached.receivedAt<=0.75 { return cached.snapshot }
            return nil
        }
        let operation=generation
        do {
            let value=try await fetch()
            try Task.checkCancellation()
            let received=now()
            let completionTime=received.isFinite && received>=t ? received:t
            guard operation==generation else { policy.cancelled(now:completionTime); return nil }
            guard received.isFinite, received>=t, received-t<2 else {
                cached=nil; policy.failed(now:completionTime); return nil
            }
            cached=(value,received); policy.succeeded(now:received); return value
        } catch is CancellationError {
            cached=nil
            let finished=now(); let safeTime=finished.isFinite && finished>=t ? finished:t
            policy.cancelled(now:safeTime); return nil
        } catch {
            cached=nil
            let finished=now(); let safeTime=finished.isFinite && finished>=t ? finished:t
            if Task.isCancelled || operation != generation { policy.cancelled(now:safeTime) }
            else { policy.failed(now:safeTime) }
            return nil
        }
    }
}
