import Foundation

/// Historical/imported body-v0 messages only. No serial port, heartbeat, arming or actuation.
struct SpatialFirmwareEvidence: Sendable {
    let type: String
    let sourceUptimeMS: UInt32
    let summary: String
    let issues: [String]
    let logicalMotionClaim: Bool?
    let hardwareValidatedClaim: Bool?
    let tractionAvailableClaim: Bool?
    let allowsActuation = false
    let measuredHeadPoseAvailable = false
    let live = false
    private struct Header: Decodable {
        let type: String; let proto: String; let version: String; let uptime: UInt32
        enum CodingKeys: String,CodingKey { case type, proto="protocol", version="protocol_version", uptime="uptime_ms" }
    }
    private struct Status: Decodable {
        let firmware: String; let transport: String; let baud: Int
        let bodyReady: Bool; let hardwareValidated: Bool; let traction: Bool; let state: String; let motion: Bool
        let estop: Bool; let recovery: Bool; let physicalEstop: Bool; let bumpers: Bool
        enum CodingKeys: String,CodingKey {
            case firmware,transport,baud,bodyReady="body_ready",hardwareValidated="hardware_validated",traction="traction_available",state="safety_state",motion="motion_allowed",estop="logical_estop_latched",recovery="recovery_required",physicalEstop="estop_input_available",bumpers="kw12_inputs_enabled"
        }
    }
    private struct Capabilities: Decodable {
        struct Features: Decodable {
            let basicMove: Bool; let panTilt: Bool; let headCenter: Bool; let lookAround: Bool; let imu: Bool
            enum CodingKeys: String,CodingKey { case basicMove="basic_move",panTilt="pan_tilt",headCenter="head_center",lookAround="look_around",imu }
        }
        let features: Features
    }
    private struct Encoders: Decodable {
        struct Counts: Decodable { let fl: Int32; let fr: Int32; let rl: Int32; let rr: Int32 }
        let available: Bool; let mode: String; let direction: Bool; let counts: Counts
        enum CodingKeys: String,CodingKey { case available,mode,counts,direction="direction_available" }
    }
    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count<=8192 else { throw SpatialError.invalidArchive }
        let decoder=JSONDecoder(); let header=try decoder.decode(Header.self,from:data)
        guard header.proto=="tars-alpha-serial-json", header.version=="body-v0" else { throw SpatialError.invalidArchive }
        var issues=["Registro importado; não é conexão ao vivo", "uptime do ESP32 sem alinhamento com relógio do XR", "Sem pan/tilt medidos; pose do corpo indisponível", "Nenhuma atuação autorizada"]
        switch header.type {
        case "status":
            let s=try decoder.decode(Status.self,from:data)
            guard s.firmware=="tars-body-v0", s.transport=="serial-json", s.baud==115200,
                  ["BOOT","SAFE_LOCKED","ARMED","MOVING","FAULT","ESTOP"].contains(s.state) else { throw SpatialError.invalidArchive }
            if !s.hardwareValidated { issues.append("Hardware não validado pelo firmware") }
            if !s.traction { issues.append("Tração indisponível") }
            if !s.physicalEstop { issues.append("Entrada de E-stop físico indisponível neste baseline") }
            if !s.bumpers { issues.append("Leitura KW12 desabilitada neste baseline") }
            if s.motion { issues.append("motion_allowed é estado lógico; não comprova tração ou segurança física") }
            if s.estop || s.recovery { issues.append("Firmware relata parada travada ou recuperação necessária") }
            if s.hardwareValidated || s.traction || s.bodyReady { issues.append("Flags diferentes do baseline auditado; exigem nova auditoria, sem liberação automática") }
            return Self(type:header.type,sourceUptimeMS:header.uptime,summary:"Body V0 · \(s.state) · diagnóstico histórico",issues:issues,logicalMotionClaim:s.motion,hardwareValidatedClaim:s.hardwareValidated,tractionAvailableClaim:s.traction)
        case "capabilities":
            let c=try decoder.decode(Capabilities.self,from:data).features
            if !c.basicMove { issues.append("basic_move indisponível") }
            if !c.panTilt || !c.headCenter || !c.lookAround { issues.append("Varredura/atuação do pescoço indisponível") }
            if c.basicMove || c.panTilt || c.headCenter || c.lookAround || c.imu { issues.append("Capacidades diferentes do baseline; presença não é validação física") }
            return Self(type:header.type,sourceUptimeMS:header.uptime,summary:"Capacidades declaradas pelo Body V0",issues:issues,logicalMotionClaim:nil,hardwareValidatedClaim:nil,tractionAvailableClaim:nil)
        case "encoders":
            let c=try decoder.decode(Encoders.self,from:data)
            guard c.mode=="single_channel_a_change_count" else { throw SpatialError.invalidArchive }
            issues.append("Contagem de transições não mede distância sem calibração; não fornece pose")
            if !c.direction { issues.append("Direção dos encoders indisponível") }
            if !c.available { issues.append("Encoders declarados indisponíveis") }
            return Self(type:header.type,sourceUptimeMS:header.uptime,summary:"Encoders A · FL \(c.counts.fl) · FR \(c.counts.fr) · RL \(c.counts.rl) · RR \(c.counts.rr)",issues:issues,logicalMotionClaim:nil,hardwareValidatedClaim:nil,tractionAvailableClaim:nil)
        default: throw SpatialError.invalidArchive
        }
    }
    static func decodeTranscript(_ data: Data) throws -> [Self] {
        guard data.count<=65536, let text=String(data:data,encoding:.utf8) else { throw SpatialError.invalidArchive }
        let lines=text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty, lines.count<=64 else { throw SpatialError.invalidArchive }
        // All-or-nothing import. Unknown records must not be silently treated as a live state.
        return try lines.map { try decode(Data($0.utf8)) }
    }
}
