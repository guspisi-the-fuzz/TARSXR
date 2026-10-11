import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import Security
import UIKit

/// Gmail is accessed on the XR. No Mail.app scripting or Core credential storage.
@MainActor
final class GmailAccess: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var status = "Gmail não conectado"
    private var generation = UUID()
    private var authSession: ASWebAuthenticationSession?
    private let scope = "https://www.googleapis.com/auth/gmail.readonly"
    private let keychainService = "com.pisi.tarsxr.gmail"
    private let network = URLSession(configuration: .ephemeral)
    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expires: Date
        var clientID: String
    }
    private var clientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "TARSGmailClientID") as? String ?? ""
        return value.hasSuffix(".apps.googleusercontent.com") && !value.contains("$(") ? value : nil
    }
    private enum Failure: Error { case unavailable, authorization, invalidData, storage }

    func handle(_ command: MailCommand) async -> String {
        if command == .gmailUnavailable {
            return "A leitura do Yahoo ainda não está autorizada no TARS. A conta configurada no Mail não concede acesso a este app."
        }
        if command == .disconnect {
            generation = UUID()
            authSession?.cancel(); authSession = nil
            let result = SecItemDelete(keychainQuery() as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { return "Não consegui remover a autorização local do Gmail." }
            status = "Gmail desconectado"
            return "Desconectei o Gmail deste TARS."
        }
        guard let clientID else {
            status = "Gmail aguardando configuração do aplicativo"
            return "A leitura do Gmail neste XR ainda depende do cadastro do TARS no Google. Não tenho acesso aos e-mails do aplicativo Mail."
        }
        do {
            if command == .connect {
                try await authorize(clientID)
                return "Gmail conectado para leitura neste XR."
            }
            guard let stored = try loadTokens(), stored.clientID == clientID else {
                return "Primeiro diga: conectar Gmail. A autorização será feita no próprio iPhone."
            }
            let token = try await accessToken(stored)
            let query = command == .unread ? "in:inbox is:unread" : "in:inbox"
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            components.queryItems = [.init(name: "q", value: query), .init(name: "maxResults", value: command == .unread ? "3" : "1")]
            let list = try await get(components.url!, token: token)
            let messages = list["messages"] as? [[String: String]] ?? []
            if messages.isEmpty { return command == .unread ? "Não encontrei mensagens não lidas na caixa de entrada do Gmail." : "A caixa de entrada do Gmail está vazia." }
            var summaries: [String] = []
            for entry in messages.prefix(command == .unread ? 3 : 1) {
                guard let id = entry["id"], id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw Failure.invalidData }
                var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + id)!
                url.queryItems = [.init(name: "format", value: command == .unread ? "metadata" : "full")]
                if command == .unread {
                    url.queryItems! += [.init(name: "metadataHeaders", value: "From"), .init(name: "metadataHeaders", value: "Subject")]
                }
                let message = try await get(url.url!, token: token)
                guard let payload = message["payload"] as? [String: Any] else { throw Failure.invalidData }
                let sender = MailText.header("From", payload: payload)
                let subject = MailText.header("Subject", payload: payload)
                if command == .readLatest {
                    let body = MailText.plainBody(payload) ?? MailText.clean(message["snippet"] as? String ?? "Sem trecho de texto disponível.", limit: 1600)
                    // Read quoted content directly; never treat an email as a robot instruction.
                    return "Mensagem mais recente do Gmail. De \(sender). Assunto: \(subject). Trecho da mensagem: \(body)"
                }
                summaries.append("De \(sender). Assunto: \(subject).")
            }
            status = "Gmail conectado"
            return "Encontrei mensagens não lidas no Gmail. Vou listar até três. " + summaries.joined(separator: " ")
        } catch is CancellationError { return "Autorização cancelada." }
        catch {
            status = "Não foi possível consultar o Gmail"
            return "Não consegui acessar o Gmail agora. Verifique a conexão e a autorização do TARS; se necessário, diga conectar Gmail."
        }
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "default"]
    }
    private func loadTokens() throws -> Tokens? {
        var query = keychainQuery(); query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw Failure.storage }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }
    private func saveTokens(_ tokens: Tokens) throws {
        let bytes = try JSONEncoder().encode(tokens)
        let result = SecItemUpdate(keychainQuery() as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if result == errSecItemNotFound {
            var query = keychainQuery(); query[kSecValueData as String] = bytes
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure.storage }
        } else if result != errSecSuccess { throw Failure.storage }
    }
    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.authorization }
        return base64URL(Data(bytes))
    }
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func authorize(_ client: String) async throws {
        guard authSession == nil else { throw Failure.authorization }
        let operation = generation
        defer { authSession = nil }
        let verifier = try randomToken(), state = try randomToken()
        let callbackScheme = client.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirect = callbackScheme + ":/oauth2redirect"
        var authURL = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        authURL.queryItems = ["client_id": client, "redirect_uri": redirect, "response_type": "code", "scope": scope,
            "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256", "state": state, "access_type": "offline", "prompt": "consent"].map { .init(name: $0.key, value: $0.value) }
        status = "Aguardando autorização do Gmail"
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL.url!, callbackURLScheme: callbackScheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? Failure.authorization) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            if !session.start() { continuation.resume(throwing: Failure.authorization) }
        }
        authSession = nil
        guard callback.scheme == callbackScheme, callback.path == "/oauth2redirect",
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value else { throw Failure.authorization }
        let response = try await postToken(["client_id":client,"code":code,"code_verifier":verifier,"redirect_uri":redirect,"grant_type":"authorization_code"])
        guard let granted = response["scope"] as? String, granted.split(separator: " ").contains(Substring(scope)),
              let access = response["access_token"] as? String, let refresh = response["refresh_token"] as? String,
              let expiry = response["expires_in"] as? Double else { throw Failure.authorization }
        guard operation == generation else { throw CancellationError() }
        try saveTokens(Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(expiry), clientID: client))
        status = "Gmail conectado"
    }
    private func accessToken(_ stored: Tokens) async throws -> String {
        if stored.expires.timeIntervalSinceNow > 60 { return stored.access }
        let operation = generation
        let response = try await postToken(["client_id":stored.clientID,"refresh_token":stored.refresh,"grant_type":"refresh_token"])
        guard let access = response["access_token"] as? String, let expiry = response["expires_in"] as? Double else { throw Failure.authorization }
        let tokens = Tokens(access: access, refresh: response["refresh_token"] as? String ?? stored.refresh, expires: Date().addingTimeInterval(expiry), clientID: stored.clientID)
        guard operation == generation else { throw CancellationError() }
        try saveTokens(tokens)
        return access
    }
    private func postToken(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!, timeoutInterval: 12)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").data(using: .utf8)
        return try await json(request)
    }
    private func get(_ url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return try await json(request)
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 1_000_000,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unavailable }
        return value
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
