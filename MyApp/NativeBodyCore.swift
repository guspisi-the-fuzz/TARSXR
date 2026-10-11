import Foundation

/// Core state and operator gate run on XR. The remote object is only the body transport.
/// This migration remains simulator-only until the physical firmware transport is validated.
@MainActor final class NativeBodyCore {
    enum State: String { case boot="BOOT", idle="IDLE", safetyStop="SAFETY_STOP", degraded="DEGRADED" }
    private(set) var state:State = .boot
    private let bridge:any TARSRuntime
    private var epoch=0
    private var movingRequest=false
    init(bridge:any TARSRuntime) { self.bridge=bridge }
    func hud() async throws -> HUDSnapshot {
        let started=ProcessInfo.processInfo.systemUptime
        do {
            let value=try await bridge.hud()
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime-started < 2 else { throw TARSClientError.rejected("TELEMETRY_STALE") }
            guard value.schemaVersion=="1.0" else { throw TARSClientError.unavailable }
            if value.system["safety"] != "CLEAR" { state = .safetyStop }
            else if state == .boot { state = .idle }
            var system=value.system
            system["autonomy"]=state.rawValue
            if state == .safetyStop { system["safety"]="STOP" }
            return HUDSnapshot(schemaVersion:value.schemaVersion,timestamp:value.timestamp,identity:value.identity,cognition:value.cognition,system:system,sensors:value.sensors,resources:value.resources,motion:value.motion)
        } catch { state = .safetyStop; throw error }
    }
    func telemetry() async throws -> TARSTelemetry { try await bridge.telemetry() }
    func command(_ action:String,params:TARSCommandParameters?) async throws -> TARSCommandReply {
        let action=action.uppercased()
        if ["STOP","ESTOP"].contains(action) {
            epoch += 1
            if action == "ESTOP" { state = .safetyStop }
            return try await bridge.command(action,params:params)
        }
        if action == "GET_STATUS" { return try await bridge.command(action,params:params) }
        guard ["MOVE","PAN","TILT","STEER","HEAD_CENTER","CLEAR_ESTOP"].contains(action) else { throw TARSClientError.rejected("UNKNOWN_ACTION") }
        let operation=epoch
        let snapshot=try await hud()
        guard snapshot.system["esp32"] == "VIRTUAL" else { throw TARSClientError.rejected("PHYSICAL_TRANSPORT_NOT_VALIDATED") }
        guard operation==epoch else { throw TARSClientError.rejected("COMMAND_CANCELLED") }
        if action != "CLEAR_ESTOP" {
            guard state == .idle, snapshot.system["safety"] == "CLEAR" else { throw TARSClientError.rejected("SAFETY_STOP_LATCHED") }
        }
        if action == "MOVE" {
            guard let direction=params?.direction?.uppercased(), ["FORWARD","BACKWARD"].contains(direction), let speed=params?.speed, speed.isFinite,(0...1).contains(speed), (1...2000).contains(params?.durationMS ?? 250) else { throw TARSClientError.rejected("INVALID_MOTION_PARAMETER") }
        }
        if ["PAN","TILT","STEER"].contains(action), params?.degrees?.isFinite != true { throw TARSClientError.rejected("INVALID_DEGREES") }
        guard !movingRequest else { throw TARSClientError.rejected("COMMAND_PENDING") }
        movingRequest=true; defer { movingRequest=false }
        do {
            let result=try await bridge.command(action,params:params)
            if operation != epoch {
                _ = try? await bridge.command("STOP",params:nil)
                throw TARSClientError.rejected("COMMAND_CANCELLED")
            }
            if !["EXECUTED","CACHED"].contains(result.status) { state = .safetyStop }
            return result
        } catch { state = .safetyStop; throw error }
    }
    func recover() async throws {
        let operation=epoch
        let snapshot=try await hud()
        guard snapshot.system["esp32"] == "VIRTUAL", operation==epoch else { throw TARSClientError.rejected("RECOVERY_INTERLOCK") }
        try await bridge.recover()
        let started=ProcessInfo.processInfo.systemUptime
        let fresh=try await bridge.hud()
        guard ProcessInfo.processInfo.systemUptime-started < 2, operation==epoch, fresh.system["esp32"] == "VIRTUAL",fresh.system["safety"] == "CLEAR" else { state = .safetyStop;throw TARSClientError.rejected("RECOVERY_INTERLOCK") }
        state = .idle
    }
}
