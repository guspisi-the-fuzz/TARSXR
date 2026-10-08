import Foundation
import Combine
import Security
import SwiftUI
import Network

@MainActor final class YahooAccess: ObservableObject {
    @Published var showsSetup = false
    @Published private(set) var status = "Yahoo não conectado"
    @Published private(set) var busy = false
    private var generation = UUID()
    private var active: YahooIMAP?
    private struct Credentials: Codable { var email: String; var password: String }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pisi.tarsxr.yahoo", kSecAttrAccount as String: "default"] }
    private enum CredentialFailure: Error { case keychain(OSStatus) }
    private func load() throws -> Credentials? {
        var q = query; q[kSecReturnData as String] = true
        var item: CFTypeRef?; let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess else { throw CredentialFailure.keychain(result) }
        guard let bytes = item as? Data else { throw YahooWire.Failure.invalid }
        return try JSONDecoder().decode(Credentials.self, from: bytes)
    }
    private func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialFailure.keychain(added) }
        } else if result != errSecSuccess { throw CredentialFailure.keychain(result) }
    }
    func connect(email: String, password: String) async -> Bool {
        guard !busy else { return false }
        let credentials = Credentials(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password.filter { !$0.isWhitespace })
        guard credentials.email.contains("@"), !credentials.password.isEmpty else { status = "Preencha o e-mail e a senha de aplicativo do Yahoo."; return false }
        busy = true; status = "Verificando conexão com o Yahoo…"
        let operation = generation, client = YahooIMAP(); active = client
        var saving = false
        defer { client.close(); active = nil; busy = false }
        do {
            try await client.open(); try await client.login(email: credentials.email, password: credentials.password)
            guard operation == generation else { return false }
            saving = true
            try save(credentials); status = "Yahoo conectado"; showsSetup = false
            recordDiagnostic(stage: "complete", code: "OK")
            return true
        } catch {
            let stage = saving ? "storage" : client.stage
            let code = diagnosticCode(error)
            recordDiagnostic(stage: stage, code: code)
            let detail: String
            switch stage {
            case "authentication": detail = "Falhou ao autenticar no Yahoo. A conta ainda não foi conectada."
            case "inbox": detail = "O Yahoo aceitou o login, mas falhou ao abrir a caixa de entrada."
            case "storage": detail = "O Yahoo aceitou o login, mas o iPhone não conseguiu guardar a autorização."
            case "greeting": detail = "A conexão abriu, mas falhou ao receber a resposta inicial do Yahoo."
            default: detail = "Não foi possível estabelecer a conexão segura com o Yahoo."
            }
            status = detail + " Código: " + code + "."
            return false
        }
    }
    private func diagnosticCode(_ error: Error) -> String {
        if case CredentialFailure.keychain(let code) = error { return "KEYCHAIN_\(code)" }
        if let error = error as? NWError {
            switch error {
            case .posix(let code): return "NETWORK_\(code.rawValue)"
            case .dns(let code): return "DNS_\(code)"
            case .tls(let code): return "TLS_\(code)"
            @unknown default: return "NETWORK_UNKNOWN"
            }
        }
        if let error = error as? YahooWire.Failure {
            switch error {
            case .server(let code): return code
            case .timeout: return "TIMEOUT"
            case .closed: return "CONNECTION_CLOSED"
            case .invalid: return "INVALID_FORMAT"
            case .rejected: return "REJECTED"
            }
        }
        return "UNEXPECTED_ERROR"
    }
    private func recordDiagnostic(stage: String, code: String) {
        #if DEBUG
        // Fixed stage/code only: never log an address, password or raw IMAP response.
        let record = ["stage": stage, "code": code, "time": ISO8601DateFormatter().string(from: Date())]
        if let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? bytes.write(to: URL.documentsDirectory.appendingPathComponent("yahoo-connection-diagnostic.json"), options: .atomic)
        }
        #endif
    }
    #if DEBUG
    /// Runs on the XR with its existing Keychain entry. Never exports account, message or credential data.
    func runDeviceCheck() async -> String {
        do {
            guard try load() != nil else { return "FAIL: No saved Yahoo credential on XR (errSecItemNotFound)" }
        } catch CredentialFailure.keychain(let code) {
            return "FAIL: Yahoo Keychain access OSStatus \(code)"
        } catch { return "FAIL: Saved Yahoo credential could not be decoded" }
        let unread = await handle(.unread)
        let unreadOK = unread.hasPrefix("Há ") || unread.hasPrefix("Não há e-mails não lidos")
        guard unreadOK else { return "FAIL: Yahoo unread query" }
        let latest = await handle(.readLatest)
        let latestOK = latest.hasPrefix("E-mail mais recente do Yahoo.") || latest.hasPrefix("A caixa de entrada do Yahoo está vazia.")
        guard latestOK else { return "FAIL: Yahoo latest-message query" }
        return "PASS: XR Keychain credential, Yahoo TLS login, read-only inbox, unread query and latest-message fetch. No credentials or message contents exported."
    }
    #endif
    func handle(_ command: MailCommand) async -> String {
        if command == .gmailUnavailable { return "O Gmail não está integrado. O e-mail do TARS usa o Yahoo." }
        if command == .clarify { return "Posso consultar os e-mails não lidos ou ler o e-mail mais recente do Yahoo. Qual dessas opções você quer?" }
        if command == .connect { showsSetup = true; return "Abra a configuração do Yahoo na tela do TARS e preencha sua conta e a senha de aplicativo." }
        if command == .disconnect {
            generation = UUID(); active?.close()
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { return "Não consegui remover a credencial local do Yahoo." }
            status = "Yahoo desconectado"; return "Desconectei o Yahoo deste XR."
        }
        guard !busy else { return "Já estou consultando o Yahoo. Aguarde um instante." }
        do {
            guard let credentials = try load() else { showsSetup = true; return "Primeiro conecte sua conta Yahoo na tela do TARS." }
            busy = true
            let operation = generation, client = YahooIMAP(); active = client
            defer { client.close(); active = nil; busy = false }
            try await client.open(); try await client.login(email: credentials.email, password: credentials.password)
            let frame = try await client.command(command == .unread ? "UID SEARCH UNSEEN" : "UID SEARCH ALL")
            let ids = YahooWire.ids(frame)
            guard operation == generation else { return "Consulta cancelada." }
            if ids.isEmpty { return command == .unread ? "Não há e-mails não lidos na caixa de entrada do Yahoo." : "A caixa de entrada do Yahoo está vazia." }
            var results = [String]()
            for id in ids.suffix(command == .unread ? 3 : 1).reversed() {
                let section = command == .unread ? "HEADER.FIELDS (FROM SUBJECT DATE)" : ""
                // PEEK preserves unread state. Fetch only a bounded prefix of large messages.
                let response = try await client.command("UID FETCH \(id) (BODY.PEEK[\(section)]<0.65536>)")
                guard let bytes = response.literals.first else { throw YahooWire.Failure.invalid }
                let raw = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
                results.append(YahooMessage.summary(raw, includeBody: command == .readLatest))
            }
            guard operation == generation else { return "Consulta cancelada." }
            status = "Yahoo conectado"
            return (command == .unread ? "Há \(ids.count) e-mails não lidos na caixa de entrada do Yahoo. Vou listar os \(results.count) mais recentes. " : "E-mail mais recente do Yahoo. ") + results.joined(separator: " ")
        } catch { return "Não consegui consultar o Yahoo agora. Verifique a internet e a autorização da conta na configuração do Yahoo." }
    }
}

struct YahooSetupView: View {
    @ObservedObject var access: YahooAccess
    @State private var email = ""
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Conta Yahoo") {
                    TextField("E-mail completo", text: $email).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Senha de aplicativo do Yahoo", text: $password).textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Gere uma senha de aplicativo chamada TARS na segurança da sua conta Yahoo. Não use a senha normal da conta.").font(.footnote)
                    Link("Gerar senha no Yahoo", destination: URL(string: "https://login.yahoo.com/account/security")!)
                }
                Section {
                    Button(access.busy ? "Conectando…" : "Conectar Yahoo") {
                        let secret = password
                        Task {
                            if await access.connect(email: email, password: secret) { password = "" }
                        }
                    }.disabled(access.busy || email.isEmpty || password.isEmpty)
                    Text(access.status).font(.footnote)
                    Button("Desconectar Yahoo", role: .destructive) { Task { _ = await access.handle(.disconnect) } }
                }
                Section {
                    Text("A credencial fica no armazenamento protegido deste iPhone. O TARS consulta mensagens sem marcar como lidas. Para ler em voz alta, o texto passa pelo serviço de voz configurado no TARS.").font(.footnote)
                }
            }.navigationTitle("Yahoo Mail")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { password = ""; dismiss() } } }
                .onDisappear { password = "" }
        }
    }
}
