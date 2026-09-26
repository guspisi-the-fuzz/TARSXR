import Foundation
import UIKit
import Combine

@MainActor
final class TarsHUDViewModel: ObservableObject {

    @Published var connected = false
    @Published var voiceState = "IDLE"
    @Published var systemRows: [(String, String)] = []
    @Published var sensorRows: [(String, String)] = []
    @Published var computeRows: [(String, String)] = []
    @Published var logLine = "BOOTING..."
    @Published var commandStatus = ""

    let baseURL: URL
    private let pairingSecret: String
    private let client: TARSClient

    init(baseURL: URL, pairingSecret: String) {
        #if DEBUG && targetEnvironment(simulator)
        let baseURL = ProcessInfo.processInfo.environment["TARS_CORE_URL"].flatMap(URL.init(string:)) ?? baseURL
        #endif
        self.baseURL = baseURL
        self.pairingSecret = pairingSecret
        self.client = TARSClient(baseURL: baseURL)
    }

    func converse(text: String, language: String) async throws -> String {
        if client.token == nil { try await client.pair(secret: pairingSecret) }
        return try await client.converse(text: text, language: language)
    }

    func transcribe(data: Data) async throws -> String {
        if client.token == nil { try await client.pair(secret: pairingSecret) }
        return try await client.transcribe(data: data)
    }

    func run() async {
        UIDevice.current.isBatteryMonitoringEnabled = true

        logLine = "PAIRING..."

        do {
            try await client.pair(secret: pairingSecret)
            logLine = "AUTHENTICATED"
        } catch {
            connected = false
            logLine = "PAIRING FAILED"
        }

        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["TARS_SIMULATOR_CHECKS"] == "1" {
            commandStatus = await SimulatorSafetyChecks.run(client: client)
        }
        #endif
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func refresh() async {
        let start = ContinuousClock.now

        do {
            if client.token == nil { try await client.pair(secret: pairingSecret) }
            let data = try await client.request(path: "v1/hud")

            let elapsed = start.duration(to: .now)

            let ms =
                Double(elapsed.components.seconds) * 1000 +
                Double(elapsed.components.attoseconds) / 1e15

            let envelope = try JSONDecoder().decode(
                APIEnvelope.self,
                from: data
            )

            guard envelope.ok else { throw TARSClientError.unavailable }
            apply(envelope.data, latencyMS: ms)

            connected = true
            logLine = envelope.data.system["safety"] == "CLEAR" ? "CORE CONNECTED" : "CHECK SAFETY STATUS"

        } catch {
            connected = false
            logLine = "CORE LINK UNAVAILABLE"
            systemRows = [("CORE", "OFFLINE"), ("ESP32", "UNAVAILABLE"), ("SAFETY", "UNKNOWN")]
            sensorRows = ["FRONT", "LEFT", "RIGHT", "REAR", "HEADING"].map { ($0, "N/A") }
            computeRows = [("NET", "N/A")]
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func simulatorCommand(_ action: String) async {
        do {
            if client.token == nil { try await client.pair(secret: pairingSecret) }
            if action == "RECOVER" {
                let telemetry = try await client.telemetry()
                if telemetry.emergencyStop {
                    _ = try await client.command("CLEAR_ESTOP", params: .init(estopGeneration: telemetry.estopGeneration))
                }
                try await client.recover()
                commandStatus = "Recuperado; movimento continua parado."
            } else {
                let params: TARSCommandParameters = action == "MOVE" ? .init(direction: "FORWARD", speed: 0.2, durationMS: 250) : .init()
                let reply = try await client.command(action, params: params)
                commandStatus = reply.reason
            }
            await refresh()
        } catch { commandStatus = error.localizedDescription }
    }
    #endif

    private func apply(_ s: HUDSnapshot, latencyMS: Double) {

        voiceState = s.cognition["voice_state"] ?? "IDLE"

        systemRows = [
            "AUTONOMY",
            "CORE",
            "AI",
            "VISION",
            "AUDIO",
            "ESP32",
            "SAFETY"
        ].map {
            (
                $0,
                s.system[$0.lowercased()]
                    ?? s.cognition[$0.lowercased()]
                    ?? "UNAVAILABLE"
            )
        }

        sensorRows = [
            "front",
            "left",
            "right",
            "rear",
            "heading"
        ].map {
            ($0.uppercased(), display(s.sensors[$0]))
        }

        let battery =
            UIDevice.current.batteryLevel >= 0
            ? "\(Int(UIDevice.current.batteryLevel * 100)) %"
            : "N/A"

        computeRows = [
            ("XR BAT", battery),
            ("THERMAL", ProcessInfo.processInfo.thermalState.label),
            ("NET", String(format: "%.0f ms", latencyMS))
        ]
    }

    private func display(_ f: HUDField?) -> String {

        guard
            let f,
            f.available,
            let v = f.value
        else {
            return "N/A"
        }

        let raw: String

        switch v {
        case .string(let x):
            raw = x

        case .number(let x):
            raw = String(format: "%.1f", x)

        case .bool(let x):
            raw = x ? "TRUE" : "FALSE"
        }

        return raw + (f.unit.map { " \($0)" } ?? "")
    }
}

struct APIEnvelope: Codable {
    let ok: Bool
    let data: HUDSnapshot
}

extension ProcessInfo.ThermalState {

    var label: String {
        switch self {
        case .nominal:
            return "NOMINAL"
        case .fair:
            return "FAIR"
        case .serious:
            return "SERIOUS"
        case .critical:
            return "CRITICAL"
        @unknown default:
            return "UNKNOWN"
        }
    }
}
