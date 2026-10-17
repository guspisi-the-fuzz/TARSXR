import Foundation

@main struct LocalActionExecutionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
            preconditionFailure("fixture did not start")
        }
        let center = LocalActionCoordinator()
        var events: [LocalActionCoordinator.Event] = []
        center.changed = { events.append($0) }
        check(center.statusAnswer().contains("nesta sessão"), "status query does not invent operations from an earlier session")
        let silence = try await center.run(kind: .music, question: "Toca uma música") {
            LocalActionResult(.succeeded, "", observation: "O player confirmou reprodução.", confirmation: "youtube.state.playing")
        }
        check(center.statusAnswer().contains("resultado foi confirmado") && center.statusAnswer().contains("player"), "status answer uses the confirmed receipt without another execution")
        check(silence.speech.isEmpty && silence.historyText.contains("youtube.state.playing"), "confirmed silent playback still supplies conversational evidence")
        check(events.map(\.phase) == [.requested, .running, .succeeded], "success is emitted only after the operation returns confirmed evidence")
        check(Set(events.map(\.id)).count == 1 && center.activeKind == nil, "one ID for a complete operation")
        check(center.cancel() == nil && events.count == 3, "cancelling after completion cannot turn success into an undo")
        for status in [LocalActionResult.Status.failed, .unconfirmed, .needsInput, .unavailable] {
            let result = try await center.run(kind: .mail, question: "Consulta") { LocalActionResult(status, "Resultado sem sucesso confirmado.") }
            check(result.status == status && center.current?.phase.rawValue == status.rawValue, "adapter state is preserved: " + status.rawValue)
        }
        _ = try await center.run(kind: .music, question: "Toca") { LocalActionResult(.needsInput, "Qual música?") }
        check(center.cancel() == nil, "normal speech completion does not cancel a pending clarification")
        check(center.cancel(includingAwaitingInput: true) == .music && center.current?.phase == .cancelled, "explicit cancellation also closes an awaiting-input request")
        do {
            _ = try await center.run(kind: .photo, question: "Fotografe") { LocalActionResult(.succeeded, "Foto salva sem evidência") }
            preconditionFailure("success without confirmation accepted")
        } catch LocalActionResult.Failure.invalidReceipt { checks += 1 }
        check(center.current?.phase == .failed && center.current?.result?.status != .succeeded, "invalid receipt cannot appear as success")
        var pending: CheckedContinuation<LocalActionResult, Error>?
        let old = Task { try await center.run(kind: .mail, question: "Pedido antigo") {
            try await withCheckedThrowingContinuation { pending = $0 }
        } }
        try await waitUntil { pending != nil }
        check(center.statusAnswer().contains("Ainda estou executando"), "running operation is not described as complete")
        let oldID = center.current!.id
        let countBeforeOverlap = events.count
        var duplicateRuns = 0
        do { _ = try await center.run(kind: .mail, question: "Duplicado") { duplicateRuns += 1; return LocalActionResult(.failed, "não") }; preconditionFailure("overlap accepted") }
        catch LocalActionResult.Failure.busy { checks += 1 }
        check(duplicateRuns == 0 && events.count == countBeforeOverlap, "duplicate/in-flight request never runs its adapter")
        check(center.cancel() == .mail && center.current?.phase == .cancelled, "explicit cancellation ends waiting")
        check(center.current?.result?.observation.contains("não foi desfeita") == true, "cancelled wait never claims reversal of an external effect")
        _ = try await center.run(kind: .external, question: "Novo pedido") { LocalActionResult(.succeeded, "Aberto", confirmation: "ios.open.accepted") }
        let newID = center.current!.id
        pending?.resume(returning: LocalActionResult(.succeeded, "Antigo terminou tarde", confirmation: "imap.peek.completed"))
        do { _ = try await old.value; preconditionFailure("late completion accepted") }
        catch is CancellationError { checks += 1 }
        check(center.current?.id == newID && newID != oldID, "late completion never overwrites a newer operation")
        check(events.filter { $0.id == oldID && $0.result != nil }.count == 1, "old operation records exactly one terminal outcome")
        var taskPending: CheckedContinuation<LocalActionResult, Error>?
        let cancelled = Task { try await center.run(kind: .photo, question: "Cancelar task") {
            try await withCheckedThrowingContinuation { taskPending = $0 }
        } }
        try await waitUntil { taskPending != nil }
        cancelled.cancel(); taskPending?.resume(returning: LocalActionResult(.succeeded, "Atrasado", confirmation: "photo.saved"))
        do { _ = try await cancelled.value; preconditionFailure("cancelled task succeeded") }
        catch is CancellationError { checks += 1 }
        check(center.current?.phase == .cancelled, "task cancellation suppresses a success received afterwards")
        var attempts = 0
        do { _ = try await center.run(kind: .external, question: "Falha") { attempts += 1; throw URLError(.notConnectedToInternet) }; preconditionFailure("error swallowed") }
        catch { checks += 1 }
        check(attempts == 1 && center.current?.phase == .failed, "failed execution is never automatically retried")

        let primary = URL(string: "https://example.invalid/primary")!, fallback = URL(string: "https://example.invalid/fallback")!
        var opened: [URL] = []
        let accepted = try await ExternalHandoff.execute(primary: primary, fallback: fallback) { url in opened.append(url); return true }
        check(accepted.status == .succeeded && opened == [primary], "accepted primary prevents unnecessary fallback")
        check(accepted.observation.contains("não foram verificados"), "OS acceptance is not a claim of loaded content or successful login")
        opened = []
        let alternative = try await ExternalHandoff.execute(primary: primary, fallback: fallback) { url in opened.append(url); return url == fallback }
        check(alternative.status == .succeeded && opened == [primary, fallback] && alternative.confirmation.contains("fallback"), "fallback is confirmed independently")
        let refused = try await ExternalHandoff.execute(primary: primary, fallback: nil) { _ in false }
        check(refused.status == .failed && refused.confirmation.isEmpty, "OS refusal never becomes success")
        var delayed: CheckedContinuation<Bool, Never>?
        var cancellationOpens = 0
        let delayedOpen = Task { try await ExternalHandoff.execute(primary: primary, fallback: fallback) { _ in
            cancellationOpens += 1
            return await withCheckedContinuation { delayed = $0 }
        } }
        try await waitUntil { delayed != nil }
        delayedOpen.cancel(); delayed?.resume(returning: false)
        do { _ = try await delayedOpen.value; preconditionFailure("cancelled handoff accepted") }
        catch is CancellationError { checks += 1 }
        check(cancellationOpens == 1, "cancelled primary callback cannot launch fallback")
        check(MusicCallbackPolicy.accepts(["id": "same-video", "token": "new"], videoID: "same-video", token: "new"), "current player page callback accepted")
        check(!MusicCallbackPolicy.accepts(["id": "same-video", "token": "old"], videoID: "same-video", token: "new"), "old callback rejected even for the same video ID")
        check(!MusicCallbackPolicy.accepts(["id": "same-video"], videoID: "same-video", token: "new") && !MusicCallbackPolicy.accepts(["id": "same-video", "token": "new"], videoID: nil, token: "new"), "missing page token or unloaded player cannot confirm playback")
        for text in ["TARS, cancela o pedido", "cancele esse pedido", "cancel the request"] {
            check(LocalActionCancellation.matches(text), "explicit local cancellation: " + text)
        }
        for text in ["pare", "stop", "pare o motor", "TARS avance", "não cancela o pedido", "cancele a memória"] {
            check(!LocalActionCancellation.matches(text), "local cancellation does not absorb physical, negative or unrelated commands")
        }
        check(VoiceInterruptionPolicy.matches("TARS, cancela o pedido") && !VoiceInterruptionPolicy.matches("TARS stop"), "named cancellation works without changing stop/motion semantics")
        for phrase in ["TARS, já terminou?", "Qual é o status do pedido?", "Como está o pedido?"] {
            check(LocalActionStatusQuestion.matches(phrase), "explicit receipt status query")
        }
        for phrase in ["qual é a velocidade do motor", "já terminou o campeonato", "não quero saber o status do pedido"] {
            check(!LocalActionStatusQuestion.matches(phrase), "status reader does not absorb motion, public or negative requests")
        }
        print("PASS: \(checks) local execution receipts, lifecycle, cancellation, stale callbacks, overlap, fallback and command-boundary checks; simulated adapters only, no apps opened, messages sent, AI, audio or movement.")
    }
}
