import Combine
import SwiftUI
import UIKit
import AVFoundation

/// One retained frame, one operation at a time. No command or safety interface.
@MainActor final class SequentialVision: ObservableObject {
    static let shared = SequentialVision()
    @Published private(set) var state = "OFF"
    @Published private(set) var detail = "Ative para observar localmente."
    @Published private(set) var fullDescription = ""
    @Published private(set) var buttonRequestPending = false
    @Published private(set) var lastFrame: Date?
    @Published private(set) var active = false
    @Published private(set) var quality: FrameQuality?
    private var policy = SequentialVisionPolicy()
    private var frame: (png: Data, signature: [UInt8], time: TimeInterval)?
    private var worker: Task<Void, Never>?
    private var analysis: Task<String, Error>?
    private var generation = UUID()
    private var stillBusy = false
    private var camera: SequentialSessionCamera?
    private var closing = false
    private var cameraLease: CameraOwnership.Lease?
    private var observers: [NSObjectProtocol] = []
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    init() {
        for name in [UIApplication.willResignActiveNotification, ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    if notification.name == UIApplication.willResignActiveNotification { self.stop("APP_INACTIVE") }
                    else if let reason = self.block { self.stop(reason) }
                }
            })
        }
    }
    private var block: String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "LOW_POWER" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "THERMAL"
        default: return nil
        }
    }
    func start() {
        guard !active, !policy.busy, !stillBusy, !closing else {
            detail = "Ativação aguardando: active=\(active), busy=\(policy.busy), foto=\(stillBusy), closing=\(closing)"
            print("[TARS_VISION]", detail)
            return
        }
        guard UIApplication.shared.applicationState == .active else { stop("APP_INACTIVE"); return }
        if let reason = block { stop(reason); return }
        guard let lease = CameraOwnership.shared.acquire(.vision) else { detail = SpatialError.cameraBusy.localizedDescription; return }
        cameraLease = lease
        active = true; state = "STARTING"; generation = UUID(); let token = generation
        let captureCamera = SequentialSessionCamera()
        camera = captureCamera
        worker = Task {
            while !Task.isCancelled, active, token == generation {
                if let reason = block { stop(reason); return }
                if policy.capture(now: now) {
                    state = "CAPTURING"
                    do {
                        let image = try await captureCamera.capture()
                        guard token == generation, active, !Task.isCancelled else { policy.finish(); return }
                        guard let normalized = (ReferencePhoto.normalize(image, maximumDimension: 640) ?? ReferencePhoto.normalize(image)), let signature = Self.signature(normalized.image) else { throw VoiceCameraError.invalidImage }
                        lastFrame = Date()
                        quality = Self.assessQuality(normalized.image)
                        if quality?.accepted == true {
                            frame = (normalized.png, signature, now); state = "OBSERVING"
                        } else {
                            // Reject the newest bad sample rather than describing an older good scene.
                            frame = nil; state = "WAITING_QUALITY"
                        }
                    } catch {
                        policy.finish()
                        guard token == generation else { return }
                        if case VoiceCameraError.denied = error { stop("DENIED") } else { stop("UNAVAILABLE") }; detail = error.localizedDescription; return
                    }
                    policy.finish()
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func stop(_ reason: String = "OFF") {
        generation = UUID(); active = false; state = reason
        worker?.cancel(); worker = nil; analysis?.cancel(); analysis = nil; frame = nil; quality = nil
        if let captureCamera = camera {
            camera = nil; closing = true
            let stoppedLease = cameraLease; cameraLease = nil
            Task {
                await captureCamera.stop()
                if let stoppedLease { CameraOwnership.shared.release(stoppedLease) }
                closing = false
            }
        }
        // Busy remains held until cancellation completion, preventing overlap on restart.
    }
    func prepareStill() async throws {
        guard !stillBusy else { throw VoiceCameraError.captureFailed }
        stillBusy = true
        stop()
        do {
            let deadline = now + 12
            while policy.busy || closing {
                guard now < deadline else { throw VoiceCameraError.captureFailed }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard let lease = CameraOwnership.shared.acquire(.photo) else { throw SpatialError.cameraBusy }
            cameraLease = lease
        } catch { stillBusy = false; throw error }
    }
    func finishStill() {
        if let lease = cameraLease, lease.mode == .photo { CameraOwnership.shared.release(lease); cameraLease = nil }
        stillBusy = false
    }
    var paidAttempts: Int { policy.calls }
    var frameStatus: String {
        guard let frame else { return "UNAVAILABLE" }
        return now - frame.time > 8 ? "STALE" : "FRESH"
    }
    private var descriptionAvailability: VisionDescriptionAvailability {
        .evaluate(active: active, state: state, qualityAccepted: quality?.accepted, captured: frame?.time, now: now)
    }
    var canAnalyze: Bool {
        guard descriptionAvailability == .ready, let frame else { return false }
        return policy.eligible(now: now, captured: frame.time, signature: frame.signature)
    }
    /// Shared button/voice path. No still capture and no implicit activation.
    func answerCurrent(question: String, using model: TarsHUDViewModel) async throws -> String {
        let captured = descriptionAvailability == .ready ? frame?.time : nil
        let answer = try await analyzeCurrent(question: question, using: model)
        try Task.checkCancellation()
        model.recordLocalExchange(question: question, answer: answer, source: .camera, capturedAt: captured)
        return answer
    }
    private func analyzeCurrent(question: String, using model: TarsHUDViewModel) async throws -> String {
        try Task.checkCancellation()
        let availability = descriptionAvailability
        guard availability == .ready, let frame else {
            detail = availability.message
            return availability.message
        }
        if let denial = policy.analysisDenial(now: now, captured: frame.time, signature: frame.signature) {
            // A simultaneous request must not overwrite the in-flight result.
            if denial != .busy { detail = denial.message }
            return denial.message
        }
        guard policy.analyze(now: now, captured: frame.time, signature: frame.signature) else { return "Já existe uma análise em andamento." }
        let token = generation
        let capturedAt = lastFrame
        let task = Task { @MainActor in
            let reply = try await model.describeImage(png: frame.png, source: "reference", question: question)
            try Task.checkCancellation()
            guard token == generation, active else { throw CancellationError() }
            detail = "Descrição do quadro de \(capturedAt?.formatted(date: .omitted, time: .standard) ?? "—"): " + reply.description
            fullDescription = detail
            return reply.description
        }
        analysis = task
        defer { policy.finish(); analysis = nil }
        do {
            return try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: { task.cancel() })
        } catch {
            if token == generation, !Task.isCancelled, !(error is CancellationError) { detail = error.localizedDescription }
            throw error
        }
    }
    func describe(using model: TarsHUDViewModel, speak: @escaping @MainActor (String) -> Void) {
        guard canAnalyze, !buttonRequestPending else { return }
        buttonRequestPending = true
        let token = generation
        Task { @MainActor in
            defer { buttonRequestPending = false }
            do {
                let answer = try await answerCurrent(question: "Descreva este quadro recente do XR. É uma amostra pontual, não um sensor de segurança. Não autorize movimento nem estime distâncias.", using: model)
                guard token == generation, active, !Task.isCancelled else { return }
                speak(answer)
            } catch { /* The error remains visible; cancelled replies are never spoken. */ }
        }
    }
    private static func assessQuality(_ image: UIImage) -> FrameQuality {
        guard let cg = image.cgImage else { return .measure([], width: 0, height: 0) }
        let side = 96
        var bytes = [UInt8](repeating: 0, count: side * side)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return .measure(ok ? bytes : [], width: side, height: side)
    }
    private static func signature(_ image: UIImage) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8)); return true
        }
        return ok ? bytes : nil
    }
}

struct SequentialVisionControls: View {
    @ObservedObject var vision: SequentialVision
    let model: TarsHUDViewModel
    let speak: @MainActor (String) -> Void
    let audioAvailable: Bool
    @State private var showsDescription = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("CAMERA: \(vision.state) · \(vision.frameStatus) · QUADRO: \(vision.lastFrame.map { String(format: "%.0fs", max(0, context.date.timeIntervalSince($0))) } ?? "N/A")")
                HStack {
                    Button(vision.active ? "Parar visão" : "Ativar visão local") {
                        if vision.active { vision.stop() } else { vision.start() }
                    }
                    Button("Descrever e falar") { vision.describe(using: model, speak: speak) }
                        .disabled(!vision.canAnalyze || vision.buttonRequestPending || !audioAvailable)
                }
                Text("IA: \(vision.paidAttempts)/5 nesta execução · intervalo mínimo 30s · exige mudança de cena")
                if let quality = vision.quality {
                    Text("QUALIDADE: \(quality.status.rawValue) · L \(Int(quality.luminance)) · N \(Int(quality.sharpness))")
                    Text(quality.message)
                }
                Text(vision.detail).lineLimit(3)
                Button("Ler descrição completa") { showsDescription = true }

            }.font(.caption).buttonStyle(.bordered)
        }
        .sheet(isPresented: $showsDescription) {
            NavigationStack {
                ScrollView {
                    Text(vision.fullDescription.isEmpty ? vision.detail : vision.fullDescription).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .navigationTitle("Descrição visual")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { showsDescription = false } } }
            }
        }
    }
}
