#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Opt-in checks against the local Virtual ESP32, never included on physical devices.
@MainActor enum SimulatorSafetyChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func run(client: TARSClient) async -> String {
        var passed: [String] = []
        var failure: String?
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw Failure(message: name) }
            passed.append(name)
        }
        do {
            _ = try await client.command("STOP")
            _ = try await client.command("PAN", params: .init(degrees: 12))
            var telemetry = try await client.telemetry()
            try check(telemetry.panDeg == 12, "Swift angle reaches Virtual ESP32")
            let moveReply = try await client.command("MOVE", params: .init(direction: "FORWARD", speed: 0.2, durationMS: 150))
            try check(moveReply.telemetry?.motionActive == true, "Motion starts (atomic command reply)")
            try await Task.sleep(for: .milliseconds(350))
            telemetry = try await client.telemetry()
            try check(!telemetry.motionActive && !telemetry.recoveryRequired, "Duration stops motion")
            _ = try await client.command("MOVE", params: .init(direction: "FORWARD", speed: 0.2, durationMS: 1000))
            _ = try await client.command("STOP")
            telemetry = try await client.telemetry()
            try check(!telemetry.motionActive, "STOP interrupts motion")
            _ = try await client.command("ESTOP")
            telemetry = try await client.telemetry()
            try check(telemetry.emergencyStop && !telemetry.motionActive, "E-STOP latches")
            do {
                _ = try await client.command("MOVE", params: .init(direction: "FORWARD", speed: 0.2, durationMS: 100))
                throw Failure(message: "Movement accepted during E-STOP")
            } catch TARSClientError.rejected(let reason) {
                try check(reason == "SAFETY_STOP_LATCHED", "Movement blocked by E-STOP")
            }
            _ = try await client.command("CLEAR_ESTOP", params: .init(estopGeneration: telemetry.estopGeneration))
            telemetry = try await client.telemetry()
            try check(!telemetry.emergencyStop && telemetry.recoveryRequired && !telemetry.motionActive, "Clear does not resume motion")
            do {
                _ = try await client.command("MOVE", params: .init(direction: "FORWARD", speed: 0.2, durationMS: 100))
                throw Failure(message: "Movement accepted before recovery")
            } catch TARSClientError.rejected(let reason) {
                try check(reason == "SAFETY_STOP_LATCHED", "Explicit recovery required")
            }
            try await client.recover()
            telemetry = try await client.telemetry()
            try check(!telemetry.recoveryRequired && !telemetry.motionActive, "Recovery leaves motion stopped")
            _ = try await client.command("PAN", params: .init(degrees: 0))
            telemetry = try await client.telemetry()
            try check(telemetry.panDeg == 0, "New command works after recovery")
        } catch {
            failure = error.localizedDescription
            _ = try? await client.command("STOP")
        }
        let summary = failure == nil ? "SIMULATOR SAFETY: \(passed.count) PASS" : "SIMULATOR SAFETY FAILED: \(failure!)"
        let report: [String: Any] = ["passed": passed, "success": failure == nil,
                                    "failure": failure ?? "", "summary": summary]
        do {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("safety-checks.json")
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { return "Não foi possível salvar o resultado dos testes." }
        print(summary)
        return summary
    }
}
#endif
