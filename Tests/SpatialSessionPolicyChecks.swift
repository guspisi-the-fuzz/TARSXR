import Foundation
@main enum SpatialSessionPolicyChecks {
    static func main() async throws {
        var count=0
        func check(_ value: Bool,_ name: String) { count+=1; precondition(value,name) }
        let (frames,sink)=SpatialFrameDelivery.makeStream()
        for n in 0..<10000 {
            sink.yield(SpatialFrameEvent(timestamp:Double(n),pose:.identity,tracking:.tracking,reason:"synthetic",anchorNames:[],mapped:false))
        }
        var iterator=frames.makeAsyncIterator()
        let newest=await iterator.next()
        check(newest?.timestamp==9999,"ten thousand pending callbacks keep only newest sample")
        sink.finish()
        let afterFinish=await iterator.next()
        check(afterFinish==nil,"bounded stream drains and terminates")
        if case .terminated=sink.yield(SpatialFrameEvent(timestamp:10001,pose:.identity,tracking:.tracking,reason:"late",anchorNames:[],mapped:false)) { check(true,"closed old generation cannot enqueue") } else { check(false,"closed old generation") }
        let (next,sink2)=SpatialFrameDelivery.makeStream()
        var iterator2=next.makeAsyncIterator()
        sink2.yield(SpatialFrameEvent(timestamp:1,pose:.identity,tracking:.initializing,reason:"new session",anchorNames:[],mapped:false))
        let nextValue=await iterator2.next()
        check(nextValue?.timestamp==1 && nextValue?.reason=="new session","new stream has no old frame")
        sink2.finish()
        var fresh=SpatialSessionWatchdog(startedAt:10,restoringSavedMap:false)
        check(fresh.evaluate(now:21,lastFrame:nil) == .healthy,"no immediate no-frame error")
        check(fresh.evaluate(now:22,lastFrame:nil) == .noFrames,"no frame timeout")
        fresh.observe(.relocalizing,now:11)
        check(fresh.evaluate(now:34,lastFrame:34) == .healthy,"fresh attempt has bounded grace")
        check(fresh.evaluate(now:35,lastFrame:35) == .newMapTimedOut,"fresh map cannot relocalize forever")
        var saved=SpatialSessionWatchdog(startedAt:10,restoringSavedMap:true)
        saved.observe(.relocalizing,now:11)
        check(saved.evaluate(now:35,lastFrame:35) == .healthy,"saved map has longer relocalization grace")
        check(saved.evaluate(now:55,lastFrame:55) == .savedMapTimedOut,"saved reference cannot wait forever")
        var running=SpatialSessionWatchdog(startedAt:0,restoringSavedMap:false)
        running.observe(.tracking,now:1)
        check(running.evaluate(now:100,lastFrame:100) == .healthy,"stable session has no startup expiry")
        running.observe(.limited,now:101)
        check(running.evaluate(now:120,lastFrame:120) == .healthy,"recoverable limited period")
        check(running.evaluate(now:121,lastFrame:121) == .recoveryTimedOut,"limited too long")
        running.observe(.tracking,now:122)
        check(running.evaluate(now:123,lastFrame:123) == .healthy,"recovery clears timer")
        check(running.evaluate(now:125,lastFrame:123) == .stale,"old sample not current")
        check(running.evaluate(now:145,lastFrame:123) == .recoveryTimedOut,"silence recovery timeout")
        var bad=SpatialSessionWatchdog(startedAt:10,restoringSavedMap:false)
        check(bad.evaluate(now:9,lastFrame:nil) == .invalidClock,"clock before start")
        check(bad.evaluate(now:.nan,lastFrame:nil) == .invalidClock,"nan clock")
        check(bad.evaluate(now:11,lastFrame:12) == .invalidClock,"future frame")
        bad.observe(.tracking,now:12)
        check(bad.evaluate(now:11,lastFrame:11) == .invalidClock,"clock regression")
        var negative=SpatialSessionWatchdog(startedAt:-1,restoringSavedMap:false)
        check(negative.evaluate(now:1,lastFrame:nil) == .invalidClock,"invalid start")
        for n in 0..<1000 {
            var isolated=SpatialSessionWatchdog(startedAt:Double(n),restoringSavedMap:false)
            isolated.observe(.tracking,now:Double(n)+1)
            isolated.observe(.limited,now:Double(n)+2)
            isolated.observe(.tracking,now:Double(n)+3)
            check(isolated.evaluate(now:Double(n)+4,lastFrame:Double(n)+4) == .healthy,"repeated recoveries do not accumulate timeout")
        }
        print("PASS: \(count) bounded newest-frame delivery, stream replacement/termination, initialization/relocalization/recovery deadlines and clock checks; synthetic frames, no camera, voice or hardware.")
    }
}
