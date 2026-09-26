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

    @Published var motionStatus = "Desconhecido"
    @Published var safetyStatus = "Desconhecida"
    @Published var virtualSimulator = false
    @Published var commandPending = false
    @Published var connectionMessage = "Conectando ao Core…"
    @Published private(set) var needsConnectionHelp = false
    private var reconnection = ReconnectionPolicy()
    private var refreshInProgress = false

    var canMove: Bool { connected && virtualSimulator && safetyStatus == "Liberado" }
    var safetyGuidance: String {
        if !connected { return connectionMessage + " Movimento desconhecido; nenhum comando será repetido." }
        if !virtualSimulator { return "Os testes só ficam disponíveis quando o Core confirma um ESP32 virtual." }
        if safetyStatus == "Bloqueado" { return "O Core mantém o movimento bloqueado. A recuperação verificará as condições de segurança antes de liberar novos comandos." }
        return "Mover envia um pulso de 250 ms ao simulador. E-STOP bloqueia novos movimentos até a recuperação."
    }

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

        await refresh()

        #if DEBUG && targetEnvironment(simulator)
        if connected && ProcessInfo.processInfo.environment["TARS_SIMULATOR_CHECKS"] == "1" {
            commandStatus = await SimulatorSafetyChecks.run(client: client)
        }
        #endif
        while !Task.isCancelled {
            let delay = connected ? 0.5 : Double(reconnection.delaySeconds)
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            if !reconnection.needsIntervention { await refresh() }
        }
    }

    func retryConnection() async {
        guard !refreshInProgress else { return }
        reconnection.reset()
        needsConnectionHelp = false
        connectionMessage = "Tentando conectar…"
        await refresh()
    }

    private func refresh() async {
        guard !refreshInProgress, !Task.isCancelled else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
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
            reconnection.reset()
            needsConnectionHelp = false
            let supervisor = envelope.data.system["supervisor"] ?? "UNMONITORED"
            if supervisor != "READY" && supervisor != "UNMONITORED" {
                switch supervisor {
                case "SUPERVISOR_RETRYING":
                    connectionMessage = "Core conectado; supervisor tentando se recuperar."
                case "SUPERVISOR_ATTENTION":
                    connectionMessage = "Falha persistente do supervisor. Verifique o Core; tentativas continuam."
                case "SUPERVISOR_STALE":
                    connectionMessage = "Supervisor sem atualização. Verifique o serviço do Core."
                default:
                    connectionMessage = "Core conectado; aguardando início do supervisor."
                }
            } else if safetyStatus == "Bloqueado" {
                connectionMessage = "Conexão restabelecida; bloqueio de segurança exige verificação."
            } else {
                connectionMessage = "Core conectado."
            }
            logLine = connectionMessage

        } catch {
            if Task.isCancelled { return }
            let rejected: Bool
            if case TARSClientError.pairingRejected = error { rejected = true }
            else { rejected = false }
            reconnection.failed(authorizationRejected: rejected)
            needsConnectionHelp = rejected
            connectionMessage = rejected
                ? "Autorização recusada. Confira o pareamento e tente novamente."
                : "Reconectando automaticamente. Próxima tentativa em \(reconnection.delaySeconds) s."
            connected = false
            motionStatus = "Desconhecido"
            safetyStatus = "Desconhecida"
            virtualSimulator = false
            logLine = connectionMessage
            systemRows = [("CORE", "OFFLINE"), ("ESP32", "UNAVAILABLE"), ("SAFETY", "UNKNOWN")]
            sensorRows = ["FRONT", "LEFT", "RIGHT", "REAR", "HEADING"].map { ($0, "N/A") }
            computeRows = [("NET", "N/A")]
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func simulatorCommand(_ action: String) async {
        guard connected, virtualSimulator else {
            commandStatus = "Teste indisponível: conecte um Core com ESP32 virtual."
            return
        }
        let serialized = action == "MOVE" || action == "RECOVER"
        if serialized && commandPending { return }
        if action == "MOVE" && !canMove { return }
        if serialized { commandPending = true }
        defer { if serialized { commandPending = false } }
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
                commandStatus = "\(action == "MOVE" ? "Mover 250 ms" : action): \(reply.status) · \(reply.reason)"
                if let telemetry = reply.telemetry {
                    motionStatus = telemetry.motionActive ? "Em movimento" : "Parado"
                }
            }
            await refresh()
        } catch {
            commandStatus = error.localizedDescription
            await refresh()
        }
    }
    #endif

    private func apply(_ s: HUDSnapshot, latencyMS: Double) {

        virtualSimulator = s.system["esp32"] == "VIRTUAL"
        safetyStatus = s.system["safety"] == "CLEAR" ? "Liberado" : s.system["safety"] == "STOP" ? "Bloqueado" : "Desconhecida"
        if s.system["esp32"] == "UNAVAILABLE" {
            motionStatus = "Desconhecido"
        } else if case .bool(let active) = s.motion["active"] {
            motionStatus = active ? "Em movimento" : "Parado"
        } else { motionStatus = "Desconhecido" }
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
