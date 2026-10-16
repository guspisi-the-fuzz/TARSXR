import Foundation
@main enum VideoFrameGateChecks {
    static func main() {
        var g = VideoFrameGate()
        precondition(!g.consume(timestamp: 0)) // unsolicited frames are ignored
        let first = g.begin(); precondition(first != nil && g.begin() == nil)
        precondition(!g.consume(timestamp: .nan))
        precondition(!g.consume(timestamp: .infinity))
        precondition(!g.consume(timestamp: -1))
        precondition(g.consume(timestamp: 10))
        precondition(!g.consume(timestamp: 11)) // one conversion per request
        let second = g.begin(); precondition(second != nil && second != first)
        precondition(!g.consume(timestamp: 10)) // duplicate frame
        precondition(!g.consume(timestamp: 9)) // out of order
        precondition(g.consume(timestamp: 13))
        precondition(g.begin() != nil); g.cancel()
        precondition(!g.consume(timestamp: 14)) // late callback after cancellation
        precondition(g.begin() != nil)
        g.close()
        precondition(g.ticket == nil && g.begin() == nil)
        precondition(!g.consume(timestamp: 15))
        print("PASS: video frame admission, duplicate requests/frames, invalid timestamps, cancellation and close; simulated frames only")
    }
}
