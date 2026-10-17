import Foundation
@main enum SpatialFourWheelChecks {
    static func main() throws {
        var count=0
        func check(_ value: Bool,_ name: String) { count+=1; precondition(value,name) }
        func rejects(_ name: String,_ body: () throws -> Void) { do { try body(); check(false,name) } catch { check(true,name) } }
        // Synthetic geometry only. These numbers are NOT the physical TARS dimensions/calibration.
        let geometry=SpatialWheelGeometry(wheelbase:0.4,track:0.3,maxLinearMPS:0.2,maxSteeringRadians:Dictionary(uniqueKeysWithValues:SpatialWheel.allCases.map{($0,Double.pi/3)}))
        let straight=try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0,forwardMPS:0.1,yawLeftRPS:0),geometry:geometry,now:10)
        check(straight.targets.count==4 && straight.targets.allSatisfy{$0.steeringLeftRadians==0 && $0.signedLinearMPS==0.1},"straight all wheels")
        let reverse=try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0,forwardMPS:-0.1,yawLeftRPS:0),geometry:geometry,now:10)
        check(reverse.targets.allSatisfy{abs($0.steeringLeftRadians)<0.00001 && $0.signedLinearMPS == -0.1},"reverse without rotating steering 180 degrees")
        let turn=try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0,forwardMPS:0.2,yawLeftRPS:0.3),geometry:geometry,now:10)
        let byWheel=Dictionary(uniqueKeysWithValues:turn.targets.map{($0.wheel,$0)})
        check(byWheel[.frontLeft]!.steeringLeftRadians>0 && byWheel[.frontRight]!.steeringLeftRadians>0,"front steer left")
        check(byWheel[.rearLeft]!.steeringLeftRadians<0 && byWheel[.rearRight]!.steeringLeftRadians<0,"rear steer opposite for coordinated four-wheel turn")
        check(byWheel[.frontRight]!.signedLinearMPS>byWheel[.frontLeft]!.signedLinearMPS,"outer wheel faster")
        check(turn.commonSpeedScale<1 && turn.targets.allSatisfy{abs($0.signedLinearMPS)<=0.200001},"one shared saturation factor")
        check(turn.simulatedOnly && !turn.actuationAuthorized,"never physical authority")
        for n in -20...20 {
            let twist=SpatialBodyTwist(rightMPS:Double(n)*0.0005,forwardMPS:0.15,yawLeftRPS:Double(n)*0.01)
            let plan=try SpatialFourWheelPlan.make(twist:twist,geometry:geometry,now:10)
            for target in plan.targets {
                let p=geometry.position(target.wheel)
                let actualRight = -sin(target.steeringLeftRadians)*target.signedLinearMPS
                let actualForward = cos(target.steeringLeftRadians)*target.signedLinearMPS
                check(abs(actualRight-(twist.rightMPS+twist.yawLeftRPS*p.z)*plan.commonSpeedScale)<0.000001,"no-slip coherent right velocity")
                check(abs(actualForward-(twist.forwardMPS+twist.yawLeftRPS*p.x)*plan.commonSpeedScale)<0.000001,"no-slip coherent forward velocity")
            }
        }
        let narrow=SpatialWheelGeometry(wheelbase:0.4,track:0.3,maxLinearMPS:0.2,maxSteeringRadians:Dictionary(uniqueKeysWithValues:SpatialWheel.allCases.map{($0,Double.pi/6)}))
        rejects("sideways beyond steering range") { _ = try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0.1,forwardMPS:0,yawLeftRPS:0),geometry:narrow,now:10) }
        rejects("spin may be mechanically infeasible") { _ = try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0,forwardMPS:0,yawLeftRPS:0.2),geometry:narrow,now:10) }
        rejects("invalid geometry") { _ = try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:0,forwardMPS:0,yawLeftRPS:0),geometry:SpatialWheelGeometry(wheelbase:0,track:0.3,maxLinearMPS:0.2,maxSteeringRadians:[:]),now:10) }
        rejects("nan intention") { _ = try SpatialFourWheelPlan.make(twist:SpatialBodyTwist(rightMPS:.nan,forwardMPS:0,yawLeftRPS:0),geometry:geometry,now:10) }
        let exact=Dictionary(uniqueKeysWithValues:turn.targets.map{($0.wheel,$0.steeringLeftRadians)})
        check(turn.alignedForSimulation(measuredAngles:exact,measuredAt:10,now:10,clockSynchronized:true),"all four aligned")
        check(!turn.alignedForSimulation(measuredAngles:exact,measuredAt:9,now:10,clockSynchronized:true),"old steering")
        check(!turn.alignedForSimulation(measuredAngles:exact,measuredAt:10,now:11,clockSynchronized:true),"old plan")
        check(!turn.alignedForSimulation(measuredAngles:exact,measuredAt:10,now:10,clockSynchronized:false),"clock mismatch")
        var wrong=exact; wrong[.rearRight]!+=0.2
        check(!turn.alignedForSimulation(measuredAngles:wrong,measuredAt:10,now:10,clockSynchronized:true),"one wheel not aligned")
        wrong.removeValue(forKey:.frontLeft)
        check(!turn.alignedForSimulation(measuredAngles:wrong,measuredAt:10,now:10,clockSynchronized:true),"missing wheel")
        print("PASS: \(count) four-wheel drive/steering kinematics, common speed saturation, mechanical infeasibility, freshness and four-wheel alignment checks. Synthetic geometry; no servo/PWM/ESP32 commands or physical validation.")
    }
}
