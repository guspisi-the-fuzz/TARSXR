import Foundation

struct TARSCommand: Codable { let intent: String; let action: String; let params: [String: Double] }
struct TARSAPIResponse<T: Decodable>: Decodable { let ok: Bool; let data: T? }
struct TranscriptionReply: Decodable { let text: String }
struct ConversationReply: Decodable { let speech: String }

enum TARSClientError: LocalizedError {
    case unavailable, unauthorized, ai(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "O Core não respondeu. Confira a conexão."
        case .unauthorized: return "Sessão expirada. Reabra o app para refazer a conexão."
        case .ai(let code):
            switch code {
            case "AI_INSUFFICIENT_QUOTA": return "A API precisa de saldo ou liberação de cota."
            case "AI_RATE_LIMIT": return "Limite temporário da API. Aguarde e tente novamente."
            case "AI_QUOTA_OR_RATE_LIMIT": return "A API está sem saldo ou no limite de uso."
            case "AI_LOCAL_LIMIT": return "Limite de testes desta sessão atingido."
            case "AI_AUTH_FAILED", "AI_ACCESS_DENIED": return "A API não autorizou esta conexão."
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
    init(baseURL: URL) { self.baseURL = baseURL }
    func pair(secret: String) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/session"))
        r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["pairing_secret": secret])
        let (data, response) = try await URLSession.shared.data(for: r)
        guard (response as? HTTPURLResponse)?.statusCode == 201,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any], let value = d["token"] as? String, !value.isEmpty else {
            token = nil; throw TARSClientError.unauthorized
        }
        token = value
    }
    func request(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 30
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw TARSClientError.unavailable }
        if http.statusCode == 401 { throw TARSClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw TARSClientError.ai(obj?["error"] as? String ?? "AI_SERVICE_ERROR")
        }
        return data
    }
    func transcribe(data: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["audio": data.base64EncodedString()])
        let result = try await request(path: "v1/transcription", method: "POST", body: body)
        let reply = try JSONDecoder().decode(TARSAPIResponse<TranscriptionReply>.self, from: result)
        guard reply.ok, let text = reply.data?.text, !text.isEmpty else { throw TARSClientError.unavailable }
        return text
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
