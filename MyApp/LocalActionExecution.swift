import Foundation

/// Receipts come only from local adapters, never from model text or a motion API.
struct LocalActionResult {
    enum Status: String { case succeeded, failed, unconfirmed, needsInput, unavailable, cancelled }
    let status: Status
    let speech: String
    let observation: String
    let confirmation: String
    init(_ status: Status, _ speech: String, observation: String? = nil, confirmation: String = "") {
        self.status = status; self.speech = speech
        self.observation = observation ?? speech; self.confirmation = confirmation
    }
    var historyText: String {
        let prefix = "Resultado local: " + status.rawValue + ". "
        let evidence = confirmation.isEmpty ? "" : "Confirmação: " + confirmation + ". "
        return String((prefix + evidence + observation).prefix(2000))
    }
    func validated() throws -> Self {
        guard speech.count <= 2000, observation.count <= 2000, confirmation.count <= 100,
              !observation.isEmpty, status != .succeeded || !confirmation.isEmpty else { throw Failure.invalidReceipt }
        return self
    }
    enum Failure: LocalizedError {
        case invalidReceipt, busy
        var errorDescription: String? {
            switch self {
            case .busy: return "Já há um pedido local em execução. Aguarde ou interrompa a espera."
            case .invalidReceipt: return "Não consegui confirmar o resultado desse pedido."
            }
        }
    }
}

@MainActor final class LocalActionCoordinator {
    enum Kind: String { case mail, music, photo, external }
    enum Phase: String { case requested, running, succeeded, failed, unconfirmed, needsInput, unavailable, cancelled }
    struct Event {
        let id: UUID
        let kind: Kind
        let question: String
        let phase: Phase
        let result: LocalActionResult?
    }
    private(set) var current: Event?
    var changed: ((Event) -> Void)?
    var activeKind: Kind? { current?.phase == .running ? current?.kind : nil }
    private func emit(_ event: Event) { current = event; changed?(event) }
    func run(kind: Kind, question: String, operation: @escaping @MainActor () async throws -> LocalActionResult) async throws -> LocalActionResult {
        try Task.checkCancellation()
        guard activeKind == nil else { throw LocalActionResult.Failure.busy }
        let id = UUID(), question = String(question.prefix(2000))
        emit(.init(id: id, kind: kind, question: question, phase: .requested, result: nil))
        emit(.init(id: id, kind: kind, question: question, phase: .running, result: nil))
        do {
            let result = try await operation().validated()
            try Task.checkCancellation()
            guard current?.id == id, activeKind != nil else { throw CancellationError() }
            emit(.init(id: id, kind: kind, question: question, phase: Phase(rawValue: result.status.rawValue)!, result: result))
            return result
        } catch {
            if current?.id == id, activeKind != nil {
                if error is CancellationError { _ = cancel() }
                else {
                    let failed = LocalActionResult(.failed, "Não consegui concluir esse pedido.", observation: "A tentativa retornou erro e não confirmou conclusão. Isso não prova que um efeito já iniciado tenha sido desfeito.")
                    emit(.init(id: id, kind: kind, question: question, phase: .failed, result: failed))
                }
            }
            throw error
        }
    }
    func statusAnswer() -> String {
        guard let event = current else { return "Não há pedido local registrado nesta sessão." }
        switch event.phase {
        case .requested: return "Recebi o último pedido local; a execução ainda não começou."
        case .running: return "Ainda estou executando o último pedido local."
        case .succeeded: return "No último pedido local, o resultado foi confirmado. " + (event.result?.observation ?? "")
        case .unconfirmed: return "Ainda não tenho confirmação de conclusão do último pedido local. " + (event.result?.observation ?? "")
        case .failed: return "A tentativa do último pedido local retornou uma falha. " + (event.result?.observation ?? "")
        case .needsInput: return event.result?.speech ?? "Preciso de uma informação sua para esse pedido."
        case .unavailable: return event.result?.speech ?? "O recurso necessário está indisponível."
        case .cancelled: return event.result?.observation ?? "A espera do último pedido local foi interrompida; não confirmei o resultado."
        }
    }

    /// Cancels waiting/acceptance of callbacks, never claims rollback of an effect.
    @discardableResult func cancel(includingAwaitingInput: Bool = false) -> Kind? {
        guard let event = current, activeKind != nil || (includingAwaitingInput && current?.phase == .needsInput) else { return nil }
        let result = LocalActionResult(.cancelled, "Interrompi a espera desse pedido.", observation: "A espera foi interrompida. Não há confirmação do resultado final; uma ação já efetuada não foi desfeita por esta interrupção.")
        emit(.init(id: event.id, kind: event.kind, question: event.question, phase: .cancelled, result: result))
        return event.kind
    }
}

/// The OS can confirm accepting a URL; it cannot confirm content loaded or login.
enum ExternalHandoff {
    @MainActor static func execute(primary: URL, fallback: URL?, open: @escaping @MainActor (URL) async -> Bool) async throws -> LocalActionResult {
        try Task.checkCancellation()
        let accepted = await open(primary)
        try Task.checkCancellation()
        if accepted { return LocalActionResult(.succeeded, "O iOS confirmou a abertura solicitada.", observation: "O iOS aceitou a URL solicitada. Carregamento do conteúdo e acesso à conta não foram verificados.", confirmation: "ios.open.accepted") }
        if let fallback {
            let fallbackAccepted = await open(fallback)
            try Task.checkCancellation()
            if fallbackAccepted { return LocalActionResult(.succeeded, "O iOS confirmou a abertura da alternativa disponível.", observation: "O iOS aceitou a URL alternativa. Carregamento do conteúdo e acesso à conta não foram verificados.", confirmation: "ios.open.fallback.accepted") }
        }
        return LocalActionResult(.failed, "O iOS não confirmou a abertura solicitada.")
    }
}

enum MusicCallbackPolicy {
    static func accepts(_ value: [String: Any], videoID: String?, token: String) -> Bool {
        guard let videoID else { return false }
        return value["id"] as? String == videoID && value["token"] as? String == token
    }
}

enum LocalActionCancellation {
    static func matches(_ raw: String) -> Bool {
        let text = SpokenRequest.clean(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.range(of: #"^(?:cancela|cancele|cancelar) (?:o |esse |este )?pedido$|^cancel (?:the |that )?request$"#, options: .regularExpression) != nil
    }
}

/// Explicit status questions read receipts; they cannot execute or retry anything.
enum LocalActionStatusQuestion {
    static func matches(_ raw: String) -> Bool {
        let text = SpokenRequest.clean(raw).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "pt_BR"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.range(of: #"^(?:ja terminou|terminou o pedido|qual (?:e )?(?:o )?status do pedido|como esta o pedido|what is the request status)$"#, options: .regularExpression) != nil
    }
}
