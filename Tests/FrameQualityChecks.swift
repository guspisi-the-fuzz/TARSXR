import Foundation
@main enum FrameQualityChecks {
    static func main() {
        let side = 96
        func measure(_ pixels: [UInt8]) -> FrameQuality {
            FrameQuality.measure(pixels, width: side, height: side)
        }
        precondition(measure([UInt8](repeating: 0, count: side*side)).status == .dark)
        precondition(measure([UInt8](repeating: 255, count: side*side)).status == .bright)
        precondition(measure([UInt8](repeating: 128, count: side*side)).status == .lowDetail)
        var sharp = [UInt8](repeating: 0, count: side*side)
        for y in 0..<side { for x in 0..<side {
            sharp[y*side+x] = (x/8 + y/8) % 2 == 0 ? 40 : 210
        } }
        let baseline = measure(sharp)
        precondition(baseline.accepted)
        var blurred = sharp
        for _ in 0..<12 {
            let old = blurred
            for y in 0..<side { for x in 0..<side {
                var total = 0
                for dy in -1...1 { for dx in -1...1 { total += Int(old[min(side-1, max(0, y+dy))*side + min(side-1, max(0, x+dx))]) } }
                blurred[y*side+x] = UInt8(total / 9)
            } }
        }
        let soft = measure(blurred)
        precondition(soft.sharpness < baseline.sharpness && !soft.accepted)
        let gradient = (0..<(side*side)).map { UInt8(50 + ($0 % side)) }
        precondition(measure(gradient).status == .lowDetail)
        precondition(measure([]).status == .invalid)
        precondition(FrameQuality.measure([0], width: Int.max, height: 2).status == .invalid)
        precondition(FrameQuality.measure(sharp, width: side, height: side, minimumSharpness: .nan).status == .invalid)
        // Dark/overexposed textured frames must not pass merely because they have edges.
        precondition(measure(sharp.map { $0 / 16 }).status == .dark)
        precondition(measure(sharp.map { 240 + $0 / 18 }).status == .bright)
        print("PASS: deterministic dark, bright, sharp, blurred, flat, gradient and invalid frames; no AI or device")
    }
}
