import Foundation
@main enum NativeBodyObservationChecks {
    enum Failure: Error { case offline }
    @MainActor static func main() async throws {
        var count=0
        func check(_ value: Bool,_ name: String) { count+=1; precondition(value,name) }
        var policy=NativeBodyObservationPolicy()
        check(policy.begin(now:0),"initial poll admitted")
        check(!policy.begin(now:1),"no duplicate in-flight poll")
        policy.failed(now:1)
        check(!policy.begin(now:1.9) && policy.begin(now:2),"first backoff")
        policy.failed(now:2)
        check(!policy.begin(now:3) && policy.begin(now:4),"second backoff")
        policy.succeeded(now:4)
        check(policy.failures==0 && !policy.begin(now:4.1) && policy.begin(now:4.5),"successful polling restored")
        policy.cancelled(now:4.5)
        check(policy.failures==0 && !policy.inFlight,"cancellation is not network failure")
        var clock=0.0; var calls=0; var offline=true
        let fixture=HUDSnapshot(schemaVersion:"1.0",timestamp:0,identity:[:],cognition:[:],system:["esp32":"VIRTUAL","safety":"CLEAR"],sensors:[:],resources:[:],motion:[:])
        let observation=NativeBodyObservation(now:{clock}) {
            calls+=1
            if offline { throw Failure.offline }; return fixture
        }
        for n in 0..<1000 {
            clock=Double(n)/2
            let value=await observation.read()
            check(value==nil,"offline never returns old body telemetry")
        }
        check(calls<30,"1000 HUD refreshes do not cause 1000 offline requests")
        offline=false; clock=observation.policy.nextAttempt
        let recovered=await observation.read()
        check(recovered?.system["esp32"]=="VIRTUAL" && observation.policy.failures==0,"read-only observation reconnects")
        let before=calls
        clock+=0.1
        let cached=await observation.read()
        check(cached != nil && calls==before,"bounded fresh cache avoids duplicate poll")
        clock+=0.5;offline=true
        let failed=await observation.read()
        check(failed==nil,"failure invalidates prior successful telemetry")
        var continuation: CheckedContinuation<HUDSnapshot,Error>?
        let pending=NativeBodyObservation(now:{clock}) {
            try await withCheckedThrowingContinuation { continuation=$0 }
        }
        let waiting=Task { await pending.read() }
        while continuation==nil { await Task.yield() }
        let duplicate=await pending.read()
        check(duplicate==nil && pending.policy.inFlight,"overlap does not launch second fetch")
        waiting.cancel();continuation?.resume(returning:fixture)
        let cancelled=await waiting.value
        check(cancelled==nil && !pending.policy.inFlight,"late cancelled response not cached")
        var staleContinuation: CheckedContinuation<HUDSnapshot,Error>?
        let invalidated=NativeBodyObservation(now:{clock}) {
            try await withCheckedThrowingContinuation { staleContinuation=$0 }
        }
        let prior=Task { await invalidated.read() }
        while staleContinuation==nil { await Task.yield() }
        invalidated.invalidate() // An explicit STOP/command invalidates all prior observation.
        staleContinuation?.resume(returning:fixture)
        let priorValue=await prior.value
        check(priorValue==nil,"late pre-command safety snapshot cannot be cached")
        check(!invalidated.policy.inFlight,"invalidated fetch releases admission")
        var slowClock=0.0
        let slow=NativeBodyObservation(now:{slowClock}) { slowClock=3;return fixture }
        let stale=await slow.read()
        check(stale==nil,"slow reply not accepted as current")
        check(slow.policy.nextAttempt==4,"slow reply backoff starts at completion, not request start")
        let slowRepeat=await slow.read()
        check(slowRepeat==nil && slow.policy.failures==1,"slow failure cannot trigger immediate repeated fetch")
        check(!NativeBodyObservationPolicy().inFlight,"independent policy")
        print("PASS: \(count) native body HUD backoff, offline isolation, bounded cache, overlap, cancellation and stale response checks. No transport or movement; explicit command/safety paths unchanged.")
    }
}
