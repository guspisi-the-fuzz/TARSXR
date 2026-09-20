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

    let baseURL: URL
    private let pairingSecret: String
    private let client: TARSClient

    init(baseURL: URL, pairingSecret: String) {
        self.baseURL = baseURL
        self.pairingSecret = pairingSecret
        self.client = TARSClient(baseURL: baseURL)
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

        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func refresh() async {
        let start = ContinuousClock.now

        do {
            let data = try await client.request(path: "v1/hud")

            let elapsed = start.duration(to: .now)

            let ms =
                Double(elapsed.components.seconds) * 1000 +
                Double(elapsed.components.attoseconds) / 1e15

            let envelope = try JSONDecoder().decode(
                APIEnvelope.self,
                from: data
            )

            apply(envelope.data, latencyMS: ms)

            connected = true
            logLine = "SYSTEMS NOMINAL"

        } catch {
            connected = false
            logLine = "CORE LINK UNAVAILABLE"
        }
    }

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
