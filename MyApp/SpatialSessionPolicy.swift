import Foundation

struct SpatialFrameEvent: Sendable {
    let timestamp: Double
    let pose: SpatialTransform
    let tracking: SpatialTracking
    let reason: String
    let anchorNames: [String]
    let mapped: Bool
}

/// One pending newest sample; the delegate never queues one main-actor Task per frame.
enum SpatialFrameDelivery: Sendable {
    static func makeStream() -> (AsyncStream<SpatialFrameEvent>, AsyncStream<SpatialFrameEvent>.Continuation) {
        let pair=AsyncStream<SpatialFrameEvent>.makeStream(bufferingPolicy:.bufferingNewest(1))
        return (pair.stream,pair.continuation)
    }
    static let publicationInterval: Double = 0.5
}

/// Device-independent clock policy. A timeout reports failure, never invents localization.
struct SpatialSessionWatchdog: Sendable {
    enum Outcome: Equatable, Sendable {
        case healthy, stale, noFrames, newMapTimedOut, savedMapTimedOut, recoveryTimedOut, invalidClock
    }
    let startedAt: Double
    let restoringSavedMap: Bool
    private(set) var everTracked=false
    private var unstableSince: Double?
    private var lastObservation: Double?
    init(startedAt: Double, restoringSavedMap: Bool) {
        self.startedAt=startedAt; self.restoringSavedMap=restoringSavedMap
    }
    mutating func observe(_ tracking: SpatialTracking, now: Double) {
        guard now.isFinite, now>=startedAt, lastObservation.map({now >= $0}) ?? true else { return }
        lastObservation=now
        if tracking == .tracking {
            everTracked=true; unstableSince=nil
        } else if everTracked && unstableSince==nil { unstableSince=now }
    }
    mutating func evaluate(now: Double, lastFrame: Double?) -> Outcome {
        guard startedAt.isFinite, startedAt>=0, now.isFinite, now>=startedAt,
              lastObservation.map({now >= $0}) ?? true,
              lastFrame.map({$0.isFinite && $0<=now}) ?? true else { return .invalidClock }
        if !everTracked {
            if lastFrame==nil && now-startedAt>=12 { return .noFrames }
            if now-startedAt >= (restoringSavedMap ? 45:25) { return restoringSavedMap ? .savedMapTimedOut:.newMapTimedOut }
        }
        if let lastFrame, now-lastFrame>1 {
            if everTracked && unstableSince==nil { unstableSince=now }
            if let unstableSince, now-unstableSince>=20 { return .recoveryTimedOut }
            return .stale
        }
        if everTracked, let unstableSince, now-unstableSince>=20 { return .recoveryTimedOut }
        return .healthy
    }
}
