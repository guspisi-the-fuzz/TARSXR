import Foundation
@main enum SpatialFirmwareChecks {
    static func main() throws {
        var checks=0
        func check(_ condition: Bool,_ name: String) { checks+=1; precondition(condition,name) }
        func rejects(_ name: String,_ block: () throws -> Void) { do { try block(); check(false,name) } catch { check(true,name) } }
        let status: [String:Any] = ["type":"status","protocol":"tars-alpha-serial-json","protocol_version":"body-v0","uptime_ms":250,"firmware":"tars-body-v0","transport":"serial-json","baud":115200,"body_ready":false,"hardware_validated":false,"traction_available":false,"safety_state":"ARMED","motion_allowed":true,"logical_estop_latched":false,"recovery_required":false,"estop_input_available":false,"kw12_inputs_enabled":false]
        func bytes(_ value: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:.sortedKeys) }
        let first=try SpatialFirmwareEvidence.decode(bytes(status))
        check(first.logicalMotionClaim==true,"preserve logical state without confusing it with readiness")
        check(first.hardwareValidatedClaim==false && first.tractionAvailableClaim==false,"physical gates")
        check(!first.allowsActuation && !first.measuredHeadPoseAvailable && !first.live,"import never enables movement")
        check(first.issues.contains(where:{$0.contains("estado lógico")}),"armed explanation")
        check(first.sourceUptimeMS==250,"uptime is source clock only")
        for key in ["protocol","protocol_version","firmware","transport","safety_state"] {
            var bad=status; bad[key]="unexpected"
            rejects("wrong version/transport/state") { _ = try SpatialFirmwareEvidence.decode(bytes(bad)) }
        }
        for key in ["motion_allowed","hardware_validated","traction_available"] {
            var bad=status; bad[key]="true"
            rejects("string is not bool") { _ = try SpatialFirmwareEvidence.decode(bytes(bad)) }
            bad=status; bad.removeValue(forKey:key)
            rejects("missing required flag") { _ = try SpatialFirmwareEvidence.decode(bytes(bad)) }
        }
        for value in [-1.0,4294967296.0,1.5] {
            var bad=status; bad["uptime_ms"]=value
            rejects("uint32 uptime") { _ = try SpatialFirmwareEvidence.decode(bytes(bad)) }
        }
        var changed=status; changed["hardware_validated"]=true; changed["traction_available"]=true; changed["body_ready"]=true; changed["pan_deg"]=90; changed["tilt_deg"]=90
        let unverified=try SpatialFirmwareEvidence.decode(bytes(changed))
        check(!unverified.allowsActuation && !unverified.measuredHeadPoseAvailable,"unverified imported true flags/angles do not grant authority")
        check(unverified.issues.contains(where:{$0.contains("nova auditoria")}),"new baseline warning")
        let capabilities: [String:Any] = ["type":"capabilities","protocol":"tars-alpha-serial-json","protocol_version":"body-v0","uptime_ms":250,"features":["basic_move":false,"pan_tilt":false,"head_center":false,"look_around":false,"imu":false]]
        let caps=try SpatialFirmwareEvidence.decode(bytes(capabilities))
        check(caps.issues.contains("basic_move indisponível"),"capabilities")
        let encoders: [String:Any] = ["type":"encoders","protocol":"tars-alpha-serial-json","protocol_version":"body-v0","uptime_ms":250,"available":true,"mode":"single_channel_a_change_count","direction_available":false,"counts":["fl":12,"fr":13,"rl":14,"rr":15]]
        let enc=try SpatialFirmwareEvidence.decode(bytes(encoders))
        check(enc.issues.contains("Direção dos encoders indisponível"),"unsigned direction unavailable")
        check(!enc.measuredHeadPoseAvailable && !enc.allowsActuation,"encoder count is not body pose")
        let joined=try bytes(status)+Data([10])+bytes(capabilities)+Data([10])+bytes(encoders)
        check(try SpatialFirmwareEvidence.decodeTranscript(joined).count==3,"three event transcript")
        rejects("unknown transcript event is not silently accepted") { _ = try SpatialFirmwareEvidence.decodeTranscript(joined+Data("\n{}".utf8)) }
        rejects("oversized transcript") { _ = try SpatialFirmwareEvidence.decodeTranscript(Data(repeating:65,count:65537)) }
        rejects("oversized event") { _ = try SpatialFirmwareEvidence.decode(Data(repeating:65,count:8193)) }
        rejects("empty") { _ = try SpatialFirmwareEvidence.decodeTranscript(Data()) }
        let path=ProcessInfo.processInfo.environment["TARS_FIRMWARE_TRANSCRIPT"] ?? "Tests/Fixtures/SpatialBodyV0.jsonl"
        if FileManager.default.fileExists(atPath:path) {
            let real=try SpatialFirmwareEvidence.decodeTranscript(Data(contentsOf:URL(fileURLWithPath:path)))
            check(real.count>=3,"actual firmware transcript")
            check(real.allSatisfy{!$0.live && !$0.allowsActuation && !$0.measuredHeadPoseAvailable},"actual firmware messages remain historical and without actuation authority")
        }
        let truncated=URL(fileURLWithPath:"Tests/Fixtures/SpatialBodyV0TruncatedHostEncoders.json")
        if FileManager.default.fileExists(atPath:truncated.path) {
            rejects("actual 64-bit host encoder serialization lacks rr; reject rather than invent zero") { _ = try SpatialFirmwareEvidence.decode(Data(contentsOf:truncated)) }
        }
        print("PASS: \(checks) body-v0 protocol, logical-vs-physical state, malformed input, uptime, unsupported head feedback, bounded historical imports and no-actuation checks; no serial/hardware commands.")
    }
}
