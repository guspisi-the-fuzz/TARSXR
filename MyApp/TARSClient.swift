import Foundation

struct TARSCommandParameters: Codable {
    var direction: String? = nil
    var speed: Double? = nil
    var durationMS: Int? = nil
    var degrees: Double? = nil
    var estopGeneration: Int? = nil
    enum CodingKeys: String, CodingKey {
        case direction, speed, degrees
        case durationMS = "duration_ms", estopGeneration = "estop_generation"
    }
}
struct TARSCommand: Codable {
    let intent: String
    let action: String
    let params: TARSCommandParameters
}
struct TARSCommandReply: Decodable { let status: String; let reason: String; let telemetry: TARSTelemetry? }
struct TARSRecoveryReply: Decodable { let recovered: Bool; let state: String }
struct TARSTelemetry: Decodable {
    let motionActive: Bool
    let emergencyStop: Bool
    let estopGeneration: Int
    let recoveryRequired: Bool
    let panDeg: Double
    enum CodingKeys: String, CodingKey {
        case motionActive = "motion_active", emergencyStop = "emergency_stop"
        case estopGeneration = "estop_generation", recoveryRequired = "recovery_required"
        case panDeg = "pan_deg"
    }
}
struct TARSAPIResponse<T: Decodable>: Decodable { let ok: Bool; let data: T? }
struct SpeechReply: Decodable { let audio: String; let format: String }
struct TranscriptionReply: Decodable { let text: String }
struct VisionReply: Decodable {
    let description: String
    let source: String
    let live_camera: Bool
    let actions_enabled: Bool
    let metric_geometry_available: Bool
}
struct ConversationReply: Decodable { let speech: String }

enum TARSClientError: LocalizedError {
    case unavailable, unauthorized, pairingRejected, ai(String), rejected(String)
    var blocksAutomaticVoice: Bool {
        switch self {
        case .pairingRejected: return true
        case .ai(let code):
            return ["AI_INSUFFICIENT_QUOTA", "AI_QUOTA_OR_RATE_LIMIT", "AI_AUTH_FAILED",
                    "AI_ACCESS_DENIED", "AI_LOCAL_LIMIT", "AI_UNCONFIGURED"].contains(code)
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "O Core não respondeu. Confira a conexão."
        case .unauthorized: return "Sessão expirada. A conexão será refeita automaticamente."
        case .pairingRejected: return "Autorização recusada. Confira o pareamento com o Core."
        case .rejected(let reason): return "Comando bloqueado: \(reason)"
        case .ai(let code):
            switch code {
            case "AI_INSUFFICIENT_QUOTA": return "A API precisa de saldo ou liberação de cota."
            case "AI_RATE_LIMIT": return "Limite temporário da API. Aguarde e tente novamente."
            case "AI_QUOTA_OR_RATE_LIMIT": return "A API está sem saldo ou no limite de uso."
            case "AI_LOCAL_LIMIT": return "Limite de testes desta sessão atingido."
            case "AI_AUTH_FAILED", "AI_ACCESS_DENIED": return "A API não autorizou esta conexão."
            case "STALE_VISION_FRAME": return "A imagem expirou antes de concluir. Você pode iniciar uma nova análise."
            case "INVALID_IMAGE": return "Não consegui usar essa imagem. Escolha outra foto."
            case "VISION_FRAME_CONFLICT", "INVALID_VISION_SCHEMA", "INVALID_VISION_REQUEST", "INVALID_VISION_FRAME", "INVALID_VISION_TIME": return "A imagem não pôde ser enviada. Selecione novamente."
            case "AI_BUSY": return "A IA está respondendo. Tente novamente em instantes."
            case "AI_UNCONFIGURED": return "A IA ainda não está configurada neste Core."
            default: return "A IA está indisponível no momento. Tente novamente."
            }
        }
    }
}

final class TARSClient {
    let baseURL: URL
    private(set) var token: String?
    private let session: URLSession
    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }
    func pair(secret: String) async throws {
        try Task.checkCancellation()
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/session"))
        r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["pairing_secret": secret])
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 || status == 403 {
            token = nil
            throw TARSClientError.pairingRejected
        }
        guard status == 201,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any], let value = d["token"] as? String, !value.isEmpty else {
            token = nil; throw TARSClientError.unavailable
        }
        token = value
    }
    func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method; r.httpBody = body; r.timeoutInterval = path == "v1/hud" ? 2 : 30
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw TARSClientError.unavailable }
        if http.statusCode == 401 { token = nil; throw TARSClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let result = obj?["data"] as? [String: Any], let reason = result["reason"] as? String {
                throw TARSClientError.rejected(reason)
            }
            if path == "v1/command" || path == "v1/recover" { throw TARSClientError.unavailable }
            throw TARSClientError.ai(obj?["error"] as? String ?? "AI_SERVICE_ERROR")
        }
        return data
    }
    func command(_ action: String, params: TARSCommandParameters? = nil) async throws -> TARSCommandReply {
        let body = try JSONEncoder().encode(TARSCommand(intent: "operator", action: action, params: params ?? .init()))
        let data = try await request(path: "v1/command", method: "POST", body: body)
        let response = try JSONDecoder().decode(TARSAPIResponse<TARSCommandReply>.self, from: data)
        guard response.ok, let reply = response.data else { throw TARSClientError.unavailable }
        return reply
    }
    func telemetry() async throws -> TARSTelemetry {
        let data = try await request(path: "v1/telemetry")
        let reply = try JSONDecoder().decode(TARSAPIResponse<TARSTelemetry>.self, from: data)
        guard reply.ok, let telemetry = reply.data else { throw TARSClientError.unavailable }
        return telemetry
    }
    func recover() async throws {
        let data = try await request(path: "v1/recover", method: "POST", body: Data("{\"confirm\":true}".utf8))
        let reply = try JSONDecoder().decode(TARSAPIResponse<TARSRecoveryReply>.self, from: data)
        guard reply.ok, reply.data?.recovered == true else { throw TARSClientError.unavailable }
    }
    func describeImage(png: Data, source: String, question: String, history: [[String: String]] = []) async throws -> VisionReply {
        try Task.checkCancellation()
        guard !png.isEmpty, png.count <= 1_000_000 else { throw TARSClientError.unavailable }
        let frame: [String: Any] = ["id": UUID().uuidString, "source": source,
            "submitted_at": Date().timeIntervalSince1970, "png": png.base64EncodedString()]
        let body = try JSONSerialization.data(withJSONObject: ["schema_version":"1.0", "frame":frame, "question":question, "history":history])
        let data = try await request(path: "v1/vision", method: "POST", body: body)
        try Task.checkCancellation()
        let reply = try JSONDecoder().decode(TARSAPIResponse<VisionReply>.self, from: data)
        guard reply.ok, let result = reply.data, !result.live_camera, !result.actions_enabled,
              !result.metric_geometry_available else { throw TARSClientError.unavailable }
        return result
    }

    func transcribe(data: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["audio": data.base64EncodedString()])
        let result = try await request(path: "v1/transcription", method: "POST", body: body)
        let reply = try JSONDecoder().decode(TARSAPIResponse<TranscriptionReply>.self, from: result)
        guard reply.ok, let text = reply.data?.text, !text.isEmpty else { throw TARSClientError.unavailable }
        return text
    }
    func streamSpeech(text: String, conversation: Bool = false, receiveText: @escaping @MainActor (String) -> Void = { _ in }, receive: @escaping @MainActor (Data) throws -> Void) async throws {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(conversation ? "v1/conversation/audio" : "v1/speech/stream"))
        request.httpMethod = "POST"; request.timeoutInterval = conversation ? 70 : 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "language": "auto", "request_id": UUID().uuidString])
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw TARSClientError.unavailable }
        if http.statusCode == 401 { token = nil; throw TARSClientError.unauthorized }
        if http.statusCode != 200 {
            var errorBody = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                errorBody.append(byte)
                guard errorBody.count <= 16384 else { throw TARSClientError.unavailable }
            }
            let object = (try? JSONSerialization.jsonObject(with: errorBody)) as? [String: Any]
            throw TARSClientError.ai(object?["error"] as? String ?? "AI_SERVICE_ERROR")
        }
        guard http.value(forHTTPHeaderField: "Content-Type") == "application/x-ndjson" else {
            throw TARSClientError.unavailable
        }
        var line = Data(); var configured = false; var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte != 10 {
                line.append(byte)
                guard line.count <= 8192 else { throw TARSClientError.unavailable }
                continue
            }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw TARSClientError.unavailable }
            line.removeAll(keepingCapacity: true)
            if let error = object["error"] as? String {
                if error == "UNAUTHORIZED" { token = nil; throw TARSClientError.unauthorized }
                throw TARSClientError.ai(error)
            }
            if !configured {
                guard object["format"] as? String == "pcm_s16le", object["rate"] as? Int == 24000,
                      object["channels"] as? Int == 1 else { throw TARSClientError.unavailable }
                configured = true; continue
            }
            if conversation, let speech = object["speech"] as? String {
                guard !speech.isEmpty, speech.count <= 2000 else { throw TARSClientError.unavailable }
                await receiveText(speech); continue
            }
            if object["done"] as? Bool == true {
                guard total > 0 else { throw TARSClientError.unavailable }
                return
            }
            guard let encoded = object["audio"] as? String, let data = Data(base64Encoded: encoded),
                  !data.isEmpty, data.count % 2 == 0 else { throw TARSClientError.unavailable }
            total += data.count
            guard total <= 4_320_000 else { throw TARSClientError.unavailable }
            try await receive(data)
        }
        throw TARSClientError.unavailable // Truncated stream must never count as completion.
    }

    func synthesize(text: String) async throws -> Data {
        try Task.checkCancellation()
        let body = try JSONSerialization.data(withJSONObject: ["text": text])
        let result = try await request(path: "v1/speech", method: "POST", body: body)
        try Task.checkCancellation()
        let reply = try JSONDecoder().decode(TARSAPIResponse<SpeechReply>.self, from: result)
        guard reply.ok, let speech = reply.data, speech.format == "mp3",
              speech.audio.count <= 2_666_668, let audio = Data(base64Encoded: speech.audio),
              !audio.isEmpty, audio.count <= 2_000_000 else { throw TARSClientError.unavailable }
        return audio
    }
    func converse(text: String, language: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "language": language,
                                                               "request_id": UUID().uuidString])
        let data = try await request(path: "v1/conversation", method: "POST", body: body)
        let reply = try JSONDecoder().decode(TARSAPIResponse<ConversationReply>.self, from: data)
        guard reply.ok, let speech = reply.data?.speech, !speech.isEmpty else { throw TARSClientError.unavailable }
        return speech
    }
}
