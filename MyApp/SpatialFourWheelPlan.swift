import Foundation

/// Kinematic simulation only. Body axes: +x right, +y up, forward = -z.
/// Four driven wheels + four steering servos; head pan/tilt are not wheel steering.
enum SpatialWheel: String, CaseIterable, Codable, Sendable { case frontLeft,frontRight,rearLeft,rearRight }
struct SpatialBodyTwist: Sendable {
    let rightMPS: Double
    let forwardMPS: Double
    let yawLeftRPS: Double
    var finite: Bool { rightMPS.isFinite && forwardMPS.isFinite && yawLeftRPS.isFinite }
}
struct SpatialWheelGeometry: Sendable {
    let wheelbase: Double
    let track: Double
    let maxLinearMPS: Double
    // Per-wheel mechanical limits relative to calibrated straight-ahead, NOT servo absolute degrees.
    let maxSteeringRadians: [SpatialWheel:Double]
    var valid: Bool {
        wheelbase.isFinite && track.isFinite && maxLinearMPS.isFinite && wheelbase>0 && track>0 && wheelbase<=10 && track<=10 && maxLinearMPS>0 && maxLinearMPS<=5 && SpatialWheel.allCases.allSatisfy { w in maxSteeringRadians[w].map { $0.isFinite && $0>0 && $0<=Double.pi/2 } ?? false }
    }
    func position(_ wheel: SpatialWheel) -> (x:Double,z:Double) {
        switch wheel {
        case .frontLeft: return (-track/2,-wheelbase/2)
        case .frontRight: return (track/2,-wheelbase/2)
        case .rearLeft: return (-track/2,wheelbase/2)
        case .rearRight: return (track/2,wheelbase/2)
        }
    }
}
struct SpatialWheelTarget: Sendable {
    let wheel: SpatialWheel
    let steeringLeftRadians: Double
    let signedLinearMPS: Double
}
struct SpatialFourWheelPlan: Sendable {
    let id: UUID
    let timestamp: Double
    let targets: [SpatialWheelTarget]
    let commonSpeedScale: Double
    let simulatedOnly = true
    let actuationAuthorized = false
    // One coherent set, never four independently clamped unrelated motor commands.
    static func make(twist: SpatialBodyTwist,geometry: SpatialWheelGeometry,now: Double) throws -> Self {
        guard geometry.valid, twist.finite, now.isFinite, now>=0,
              abs(twist.rightMPS)<=5, abs(twist.forwardMPS)<=5, abs(twist.yawLeftRPS)<=10 else { throw SpatialFourWheelError.invalidInput }
        var targets=[SpatialWheelTarget]()
        for wheel in SpatialWheel.allCases {
            let p=geometry.position(wheel)
            let right=twist.rightMPS+twist.yawLeftRPS*p.z
            let forward=twist.forwardMPS+twist.yawLeftRPS*p.x
            var speed=hypot(right,forward)
            var angle=speed<0.000001 ? 0:atan2(-right,forward)
            if angle>Double.pi/2 { angle-=Double.pi; speed = -speed }
            if angle < -Double.pi/2 { angle+=Double.pi; speed = -speed }
            guard abs(angle)<=(geometry.maxSteeringRadians[wheel] ?? 0)+0.000001 else { throw SpatialFourWheelError.steeringInfeasible }
            targets.append(SpatialWheelTarget(wheel:wheel,steeringLeftRadians:angle,signedLinearMPS:speed))
        }
        let maximum=targets.map{abs($0.signedLinearMPS)}.max() ?? 0
        let scale=maximum>geometry.maxLinearMPS ? geometry.maxLinearMPS/maximum:1
        return Self(id:UUID(),timestamp:now,targets:targets.map { SpatialWheelTarget(wheel:$0.wheel,steeringLeftRadians:$0.steeringLeftRadians,signedLinearMPS:$0.signedLinearMPS*scale) },commonSpeedScale:scale)
    }
    func alignedForSimulation(measuredAngles: [SpatialWheel:Double],measuredAt: Double,now: Double,clockSynchronized: Bool) -> Bool {
        guard simulatedOnly, !actuationAuthorized, now.isFinite, measuredAt.isFinite,
              clockSynchronized, now>=timestamp, now-timestamp<=0.5, now>=measuredAt, now-measuredAt<=0.1,
              targets.count==4, Set(targets.map(\.wheel)).count==4 else { return false }
        return targets.allSatisfy { t in measuredAngles[t.wheel].map { $0.isFinite && abs($0-t.steeringLeftRadians)<=Double.pi/180*3 } ?? false }
    }
}
enum SpatialFourWheelError: LocalizedError {
    case invalidInput, steeringInfeasible
    var errorDescription: String? {
        switch self {
        case .invalidInput: return "Geometria, limites ou intenção de movimento inválidos para simulação."
        case .steeringInfeasible: return "Movimento excede limites de direção. Replanejar; não limitar cada roda separadamente."
        }
    }
}
