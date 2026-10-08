import AVFoundation
import Speech
import Combine
import NaturalLanguage
import UIKit

@MainActor
final class XRAudioController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var state = "IDLE"
    @Published private(set) var status = "NOT ENABLED" { didSet { writeVoiceDiagnostic() } }
    @Published private(set) var transcript = ""
    @Published private(set) var lastHeard = ""
    @Published private(set) var voiceProgress = ""
    @Published private(set) var message = "Diga TARS para conversar quando a escuta estiver disponível."
    @Published private(set) var level: Double = 0
    @Published private(set) var inputName = ""
    @Published private(set) var bluetoothConnected = false
    @Published private(set) var bluetoothDevice = ""
    private func writeVoiceDiagnostic(errorCode: String? = nil, failedStage: String? = nil) {
        #if DEBUG
        // Only state metadata: never speech, images, audio or credentials.
        var diagnostic: [String: Any] = ["status": status, "state": state,
            "visual_session": visualRespond != nil, "hands_free": handsFree,
            "service_blocked": voiceServiceBlocked, "uploads": onlineTrial.uploads,
            "awaiting_request": voicePolicy.awaitingRequest,
            "follow_up_active": voicePolicy.acceptsFollowUp(),
            "timestamp": Date().timeIntervalSince1970]
        if let errorCode { diagnostic["error"] = errorCode }
        if let failedStage { diagnostic["failed_stage"] = failedStage }
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("voice-diagnostic.json"), options: .atomic)
        if errorCode != nil {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("voice-last-error.json"), options: .atomic)
        }
        #endif
    }
    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    // The early conversation path must not bypass the streaming containment.
    private let pipelinedConversation = VoicePlaybackPolicy.shouldStream(
        configuration: ProcessInfo.processInfo.environment["TARS_EARLY_RESPONSE"],
        available: true,
        visualSession: false
    )
    var streamConversation: ((String, @escaping @MainActor (Data) throws -> Void, @escaping @MainActor (String) -> Void) async throws -> Void)?
    var streamSpeech: ((String, @escaping @MainActor (Data) throws -> Void) async throws -> Void)?
    private var streamedPlayer: BufferedVoicePlayer?
    private let streamingConfiguration = ProcessInfo.processInfo.environment["TARS_STREAM_VOICE"]
    var synthesize: ((String) async throws -> Data)?
    @Published private(set) var voiceSource = "Voz sintetizada local"
    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var language = "pt-BR"
    // Explicitly enabled only after consent to online wake transcription.
    private let onlineWake = ProcessInfo.processInfo.environment["TARS_ONLINE_WAKE"] == "1"
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    var transcribe: ((Data) async throws -> String)?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    var mediaInterruptionPhrase: ((String) -> String?)?
    var acceptsMediaSpeech: ((String) -> Bool)?
    var keepsMediaSessionActive: (() -> Bool)?
    var handlesLocally: ((String) -> Bool)?
    var respond: ((String, String) async throws -> String)?
    var wakeRespond: ((String, String) async throws -> String)?
    var visualRespond: ((String) async throws -> String)?
    @Published var useAI = false
    private var tapInstalled = false
    
private let bluetooth = BluetoothManager()
    private var generation = UUID()
    private var captureWindow = VoiceCaptureWindow(now: ProcessInfo.processInfo.systemUptime)
    private var utterance: AVSpeechUtterance?
    private var interruption: NSObjectProtocol?
    private(set) var handsFree = false
    private var voiceServiceBlocked = false
    private var resumeAfterInterruption = false
    private var voicePolicy = VoiceActivationPolicy()
    private var restartTask: Task<Void, Never>?
    private var onlineTrial = OnlineVoiceTrialBudget.configured(ProcessInfo.processInfo.environment["TARS_VOICE_SESSION"])
    private var trialDeadline: Task<Void, Never>?
    #if DEBUG
    // Explicit diagnostic injection; absent from release and normal launches.
    private var simulatedCapture: (() -> Void)?
    private var simulatedOutput: ((String) -> Void)?
    private var testNaturalVoice = false
    #endif
    #if DEBUG
    private var voiceLatency: [String: Double] = [:]
    private var responseStartedAt: TimeInterval?
    private func beginResponseTiming() {
        voiceLatency = [:]
        responseStartedAt = ProcessInfo.processInfo.systemUptime
    }
    private func recordLatency(_ stage: String, since start: TimeInterval) {
        let seconds = ProcessInfo.processInfo.systemUptime - start
        voiceLatency[stage] = seconds
        // Durations only. No transcript, response, audio, tokens or credentials.
        print("[TARS_VOICE] \(stage)=\(String(format: "%.3f", seconds))")
        guard let data = try? JSONSerialization.data(withJSONObject: voiceLatency, options: [.sortedKeys]) else { return }
        // Overwrite only the latest timings. Never persist speech, text or credentials.
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("voice-latency.json"), options: .atomic)
    }

    #endif

    private func endOnlineTrial() {
        suspendHandsFree()
        if onlineTrial.isTrial {
            status = "TRIAL FINISHED"
            message = "Sessão de diagnóstico encerrada: \(onlineTrial.uploads) de \(onlineTrial.maxUploads) envios; limite de \(Int(onlineTrial.duration / 60)) minutos."
        } else {
            status = "CLOCK UNAVAILABLE"
            message = "Escuta pausada: relógio de execução indisponível."
        }
    }

    func enableHandsFree() async {
        guard !handsFree, !voiceServiceBlocked else { return }
        if onlineWake {
            onlineTrial.begin(now: ProcessInfo.processInfo.systemUptime)
            guard onlineTrial.available(now: ProcessInfo.processInfo.systemUptime) else {
                endOnlineTrial(); return
            }
            if onlineTrial.isTrial && trialDeadline == nil {
                trialDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.onlineTrial.duration ?? 180)) } catch { return }
                    self?.endOnlineTrial()
                }
            }
        }
        handsFree = true
        useAI = true
        voicePolicy.reset()
        await start()
    }

    func suspendHandsFree() {
        resumeAfterInterruption = false
        handsFree = false
        restartTask?.cancel(); restartTask = nil
        voicePolicy.reset()
        cancel(message: "Escuta pausada fora do app ou durante interrupção.")
    }

    /// WebKit may interrupt native capture without an end notification. Only
    /// recover when the visible player confirms a playing or paused session.
    /// A paused song must retain microphone access to hear the resume command.
    func resumeAfterMediaSession() {
        guard resumeAfterInterruption, !handsFree,
              keepsMediaSessionActive?() == true, !voiceServiceBlocked,
              UIApplication.shared.applicationState == .active else { return }
        resumeAfterInterruption = false
        handsFree = true
        scheduleListening()
    }

    private func scheduleListening() {
        guard handsFree else { return }
        restartTask?.cancel()
        let delay = voicePolicy.retrySeconds
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.handsFree, !Task.isCancelled else { return }
            await self.start()
        }
    }

    override init() {
        super.init()
        if ProcessInfo.processInfo.environment["TARS_PAUSE_VOICE"] == "1" {
            message = "Escuta pausada. Core conectado para acompanhar o sistema."
        }
        speaker.delegate = self
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let self else { return }
            Task { @MainActor in
                if value == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.resumeAfterInterruption || self.handsFree
                    self.handsFree = false
                    self.restartTask?.cancel(); self.restartTask = nil
                    self.cancel(message: "Escuta interrompida pelo sistema de áudio.")
                    self.writeVoiceDiagnostic(failedStage: "AUDIO_INTERRUPTION")
                } else if self.resumeAfterInterruption && UIApplication.shared.applicationState == .active {
                    self.resumeAfterInterruption = false
                    self.handsFree = true
                    self.scheduleListening()
                }
            }
        }
    }

    func start() async {
        guard state == "IDLE" else { return }
        if handsFree && onlineWake && !onlineTrial.available(now: ProcessInfo.processInfo.systemUptime) {
            endOnlineTrial(); return
        }
        generation = UUID()
        let id = generation

        bluetooth.refresh()

        bluetoothConnected = bluetooth.isConnected
        bluetoothDevice = bluetooth.deviceName
        #if DEBUG
        if let simulatedCapture {
            state = "LISTENING"
            status = voicePolicy.awaitingRequest ? "LISTENING" : "WAITING_WAKE"
            simulatedCapture()
            return
        }
        #endif
        state = "AUTHORIZING"
        message = "Aguardando permissão de microfone e reconhecimento."
        if useAI && (!handsFree || onlineWake) {
            let mic = await AVAudioApplication.requestRecordPermission()
            guard id == generation else { return }
            guard mic else { handsFree = false; fail("Permita o microfone nos Ajustes."); return }
            startMultilingualCapture(id: id)
            return
        }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard id == generation else { return }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard id == generation else { return }
        guard speech == .authorized, mic else {
            handsFree = false
            state = "IDLE"; status = "PERMISSION DENIED"
            message = "Permita microfone e reconhecimento nos Ajustes para falar."
            return
        }
        #if DEBUG
        print("[TARS_VOICE] recognition=local-\(language); bilingual_auto=false")
        #endif
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        guard let recognizer, recognizer.isAvailable else {
            fail("Reconhecimento de voz indisponível. Tente novamente."); return
        }
        if handsFree && !recognizer.supportsOnDeviceRecognition {
            handsFree = false
            fail("Reconhecimento local indisponível neste dispositivo. Ativação por voz não iniciada.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            let captureOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != captureOptions {
                try session.setCategory(.playAndRecord, mode: .default, options: captureOptions)
            }
            try session.setActive(true)
            inputName = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("Microfone indisponível neste dispositivo."); return
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = handsFree
            req.contextualStrings = ["TARS", "TARS pause", "TARS pausa", "TARS pare a música", "TARS stop", "TARS continua com a música", "TARS play the music", "TARS pause the music"]
            request = req
            transcript = ""; level = 0; captureWindow = VoiceCaptureWindow(now: ProcessInfo.processInfo.systemUptime)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let amplitude = Self.amplitude(buffer)
                Task { @MainActor in
                    guard let self, self.generation == id, self.state == "LISTENING" else { return }
                    self.level = self.level * 0.25 + amplitude * 0.75
                    if amplitude > 0.08 { self.captureWindow.observeVoice(now: ProcessInfo.processInfo.systemUptime) }
                }
            }
            tapInstalled = true
            state = "LISTENING"; status = "LISTENING"
            status = handsFree && !voicePolicy.awaitingRequest && !voicePolicy.acceptsFollowUp() ? "WAITING_WAKE" : "LISTENING"
            message = handsFree
                ? ((voicePolicy.awaitingRequest || voicePolicy.acceptsFollowUp()) ? "Estou ouvindo. Pode falar." : "Diga TARS para conversar.")
                : "Estou ouvindo… pause ao terminar ou toque em Concluir."
            recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failureCode = (error as NSError?).map { "\($0.domain)/\($0.code)" }
                Task { @MainActor in
                    guard let self, self.generation == id, self.state == "LISTENING" else { return }
                    if let text {
                        self.transcript = text
                        if let command = self.mediaInterruptionPhrase?(text) {
                            self.transcript = command
                            self.finish()
                            return
                        }
                    }
                    if final { self.finish() }
                    else if let failureCode {
                        // Initialization failure is not recovered by repeating the same request.
                        // Keep online capture opt-in; never upload ambient audio as a fallback.
                        if failureCode == "kLSRErrorDomain/300" {
                            self.handsFree = false
                            self.restartTask?.cancel(); self.restartTask = nil
                            self.fail("Escuta local indisponível neste dispositivo. No simulador, inicie o teste online autorizado; não há escuta ativa agora.")
                            return
                        }
                        let selectedLanguage = self.language == "en-US" ? "inglês" : "português"
                        self.fail("Reconhecimento em \(selectedLanguage) indisponível (\(failureCode)). O teste local está indisponível. Tente novamente.")
                    }
                }
            }
            engine.prepare(); try engine.start()
            timeout = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, self.generation == id,
                          self.state == "LISTENING" else { return }
                    switch self.captureWindow.decision(
                        now: ProcessInfo.processInfo.systemUptime,
                        hasTranscript: !self.transcript.isEmpty
                    ) {
                    case .finish: self.finish(); return
                    case .discard:
                        // A silent/empty capture must not revoke an already-authorized
                        // wake or follow-up conversation. Preserve the current policy state.
                        self.voiceProgress = self.voicePolicy.awaitingRequest
                            ? "Não ouvi uma frase. Ainda estou esperando sua pergunta."
                            : self.voicePolicy.acceptsFollowUp()
                                ? "Não ouvi uma frase. Pode continuar sem dizer TARS."
                                : "Não ouvi uma frase."
                        self.cancel(
                            message: self.handsFree
                                ? ((self.voicePolicy.awaitingRequest || self.voicePolicy.acceptsFollowUp())
                                    ? "Estou ouvindo. Pode tentar de novo."
                                    : "Diga TARS para conversar.")
                                : "Não ouvi uma frase."
                        )
                        return
                    case .keepListening: break
                    }
                }
            }
        } catch { fail("Não foi possível iniciar o áudio: \(error.localizedDescription)") }
    }

    private func startMultilingualCapture(id: UUID) {
        #if DEBUG
        print("[TARS_VOICE] recognition=online-multilingual; language_hint=none")
        #endif
        do {
            let session = AVAudioSession.sharedInstance()
            let captureOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != captureOptions {
                try session.setCategory(.playAndRecord, mode: .default, options: captureOptions)
            }
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tars-\(UUID().uuidString).wav")
            recordingURL = url
            let recording = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            recorder = recording
            recording.isMeteringEnabled = true
            guard recording.record() else { fail("Não foi possível abrir o microfone."); return }
            inputName = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            transcript = ""; level = 0; captureWindow = VoiceCaptureWindow(now: ProcessInfo.processInfo.systemUptime)
            state = "LISTENING"; status = "LISTENING"
            if voiceProgress.isEmpty { voiceProgress = "Capturando áudio; faça uma pausa ao terminar." }
            let followUp = visualRespond != nil || voicePolicy.acceptsFollowUp()
            status = handsFree && !voicePolicy.awaitingRequest && !followUp ? "WAITING_WAKE_ONLINE" : "LISTENING"
            message = handsFree && !voicePolicy.awaitingRequest && !followUp
                ? "Escuta online · PT/EN · diga TARS / say TARS"
                : "Pode falar em português ou inglês / Speak Portuguese or English."
            timeout = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.generation == id,
                          self.state == "LISTENING", let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let power = Double(recorder.averagePower(forChannel: 0))
                    self.level = min(1, max(0, (power + 55) / 45))
                    if power > -50 { self.captureWindow.observeVoice(now: ProcessInfo.processInfo.systemUptime) }
                    switch self.captureWindow.decision(now: ProcessInfo.processInfo.systemUptime) {
                    case .finish: self.finish(); return
                    case .discard:
                        // Online/multilingual silence must not revoke an already-authorized
                        // wake or follow-up conversation.
                        self.voiceProgress = self.voicePolicy.awaitingRequest
                            ? "Não ouvi uma frase. Ainda estou esperando sua pergunta."
                            : self.voicePolicy.acceptsFollowUp()
                                ? "Não ouvi uma frase. Pode continuar sem dizer TARS."
                                : "Não detectei fala."
                        self.cancel(
                            message: self.handsFree
                                ? ((self.voicePolicy.awaitingRequest || self.voicePolicy.acceptsFollowUp())
                                    ? "Estou ouvindo. Pode tentar de novo."
                                    : "Aguardando TARS / Waiting for TARS")
                                : "Não detectei fala."
                        )
                        return
                    case .keepListening: break
                    }
                }
            }
        } catch { fail("Não foi possível iniciar o áudio: \(error.localizedDescription)") }
    }

    private func finishMultilingualCapture() {
        recorder?.stop()
        guard let url = recordingURL, let data = try? Data(contentsOf: url),
              let transcribe, let respond else {
            fail("A conexão de voz com o Core ainda não está pronta."); return
        }
        processCapturedAudio(data, transcribe: transcribe, respond: respond)
    }

    private func processCapturedAudio(_ data: Data,
        transcribe: @escaping (Data) async throws -> String,
        respond: @escaping (String, String) async throws -> String) {
        stopCapture()
        let id = generation
        let capturedAt = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        beginResponseTiming()
        #endif
        state = "TRANSCRIBING"; status = "TRANSCRIBING"
        message = "Entendendo sua fala…"
        voiceProgress = "Enviando áudio para transcrição…"
        conversationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == id else { return }
            do {
                if self.handsFree && self.onlineWake {
                    guard self.onlineTrial.reserveUpload(now: ProcessInfo.processInfo.systemUptime) else {
                        self.endOnlineTrial(); return
                    }
                }
                self.voiceProgress = self.onlineTrial.isTrial
                    ? "Transcrevendo · envio \(self.onlineTrial.uploads)/\(self.onlineTrial.maxUploads)"
                    : "Transcrevendo · envio \(self.onlineTrial.uploads)"
                #if DEBUG
                let transcriptionStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let text = try await transcribe(data)
                guard !Task.isCancelled, self.generation == id else { return }
                #if DEBUG
                self.recordLatency("transcription_seconds", since: transcriptionStarted)
                #endif
                guard let request = self.routeRecognizedSpeech(
                    text,
                    capturedAt: capturedAt,
                    respond: respond
                ) else { return }
                self.transcript = request
                self.state = "THINKING"; self.status = "THINKING"
                self.message = "TARS está pensando…"
                self.voiceProgress = "Pergunta reconhecida; aguardando resposta da IA."
                #if DEBUG
                let answerStarted = ProcessInfo.processInfo.systemUptime
                #endif
                if self.visualRespond == nil, self.handlesLocally?(request) != true, self.pipelinedConversation, let streamConversation = self.streamConversation {
                    self.speakStreamed(request, isConversation: true) { [weak self] question, receive in
                        var display = ""
                        try await streamConversation(question, receive) { part in
                            guard let self, self.generation == id else { return }
                            display += (display.isEmpty ? "" : " ") + part
                            self.message = display
                        }
                    }
                    return
                }
                let answer: String
                if let visual = self.visualRespond { answer = try await visual(request) }
                else { answer = try await respond(request, "auto") }
                guard !Task.isCancelled, self.generation == id else { return }
                #if DEBUG
                self.recordLatency("answer_seconds", since: answerStarted)
                #endif
                if answer.isEmpty { self.completedSpeech() } else { self.speak(answer) }
            } catch {
                guard !Task.isCancelled, self.generation == id else { return }
                self.failService(error)
            }
        }
    }

    nonisolated private static func amplitude(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let values = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += values[i] * values[i] }
        let rms = sqrt(Double(sum) / Double(buffer.frameLength))
        return min(1, max(0, (20 * log10(max(rms, 0.00001)) + 55) / 45))
    }

    private func stopCapture() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        recorder?.stop(); recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil; level = 0
    }

    func finish() {
        guard state == "LISTENING" else { return }
        if recorder != nil { finishMultilingualCapture(); return }
        let recognized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopCapture()
        #if DEBUG
        beginResponseTiming()
        #endif
        guard let text = routeRecognizedSpeech(
            recognized,
            respond: self.respond
        ) else { return }
        guard !text.isEmpty else { cancel(message: "Nenhuma fala reconhecida."); return }
        if useAI {
            guard let respond else { fail("A conexão com a IA ainda não está pronta."); return }
            let id = generation
            state = "THINKING"; status = "THINKING"
            message = "TARS está pensando…"
            conversationTask = Task { [weak self] in
                guard let self, !Task.isCancelled, self.generation == id else { return }
                do {
                    #if DEBUG
                    let answerStarted = ProcessInfo.processInfo.systemUptime
                    #endif
                    let answer: String
                    if let visual = self.visualRespond { answer = try await visual(text) }
                    else { answer = try await respond(text, self.language) }
                    guard !Task.isCancelled, self.generation == id else { return }
                    #if DEBUG
                    self.recordLatency("answer_seconds", since: answerStarted)
                    #endif
                    if answer.isEmpty { self.completedSpeech() } else { self.speak(answer) }
                } catch {
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.failService(error)
                }
            }
            return
        }
        let prefix = language == "en-US" ? "You said" : "Você disse"
        let spoken = AudioTestPronunciation.spokenText(text, language: language)
        speak("\(prefix): \(String(spoken.prefix(120)))")
    }

    private func routeRecognizedSpeech(
        _ text: String,
        capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        respond: ((String, String) async throws -> String)? = nil
    ) -> String? {
        lastHeard = String(text.prefix(300))
        guard handsFree else { return text }
        // The explicit visual session already grants conversational attention.
        // Its owner bounds duration and questions and clears this closure on stop.
        if visualRespond != nil {
            let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else {
                cancel(message: "Não detectei fala. Pode perguntar sobre a foto.")
                return nil
            }
            transcript = question
            voiceProgress = "Pergunta sobre a foto reconhecida; preparando resposta."
            return question
        }
        if acceptsMediaSpeech?(text) == false {
            transcript = ""
            cancel(message: "Música tocando. Diga TARS antes de conversar.")
            return nil
        }
        switch voicePolicy.consume(text, now: capturedAt) {
        case .continueListening:
            transcript = ""
            voiceProgress = "TARS já está acordado; aguardando sua pergunta."
            cancel(message: "Estou ouvindo.")
            return nil
        case .sleep:
            transcript = ""
            voiceProgress = "TARS em espera; diga TARS ou Wake up para acordar."
            cancel(message: "Aguardando TARS / Waiting for TARS")
            return nil
        case .ignore:
            voiceProgress = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Nenhuma fala reconhecida."
                : "Transcrição recebida, mas não identifiquei TARS."
            transcript = ""
            cancel(message: "Aguardando TARS / Waiting for TARS")
            return nil
        case .acknowledge:
            voiceProgress = "TARS reconhecido; verificando estado interno."
            let id = generation

            Task { [weak self] in
                guard let self, !Task.isCancelled, self.generation == id else { return }

                do {
                    guard let wakeRespond = self.wakeRespond ?? respond else {
                        self.speak("Online. Ready to assist.")
                        return
                    }

                    let summary = try await wakeRespond(
                        "What is in your mind? Give a concise readiness summary in one sentence, then ask how you can help.",
                        "auto"
                    )

                    guard !Task.isCancelled, self.generation == id else { return }
                    self.speak(summary)
                } catch {
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.speak("Online. Ready to assist.")
                }
            }

            return nil
        case .request(let request):
            voiceProgress = "Pergunta reconhecida; preparando resposta."
            transcript = request
            return request
        }
    }

    func testVoice() {
        guard state == "IDLE" else { return }
        speak(language == "en-US"
              ? "Hello! I am TARS. My voice is ready for testing."
              : "Olá! Eu sou o TARS. Minha saída de áudio está pronta para o teste.")
    }

    /// Explicit reference-image output never starts or resumes microphone capture.
    func speakVisionDescription(_ text: String) {
        suspendHandsFree()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000 else { return }
        useAI = true
        speak(text)
    }

    private func speak(_ text: String) {
        #if DEBUG
        if simulatedOutput != nil && !testNaturalVoice { speakLocally(text); return }
        #endif
        guard useAI else { speakLocally(text); return }
        if VoicePlaybackPolicy.shouldStream(
            configuration: streamingConfiguration,
            available: streamSpeech != nil,
            visualSession: visualRespond != nil
        ), let streamSpeech {
            #if DEBUG
            print("[TARS_VOICE] delivery=stream")
            #endif
            speakStreamed(text, stream: streamSpeech)
            return
        }
        guard let synthesize else {
            fail("A voz do TARS ainda não está conectada. A resposta continua em texto.")
            return
        }
        #if DEBUG
        print("[TARS_VOICE] delivery=batch")
        #endif
        speechTask?.cancel()
        let id = generation
        state = "PREPARING"; status = "PREPARING"
        message = text
        voiceSource = "Voz gerada por IA"
        voiceProgress = "Preparando voz natural…"
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == id else { return }
            do {
                #if DEBUG
                let synthesisStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let data = try await synthesize(text)
                guard !Task.isCancelled, self.generation == id else { return }
                let session = AVAudioSession.sharedInstance()
                try configureVoiceOutputSession(keepingMedia: self.keepsMediaSessionActive?() == true)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: data)
                guard player.duration > 0, player.duration <= 90 else { throw TARSClientError.unavailable }
                self.audioPlayer = player
                player.delegate = self
                guard player.play() else { throw TARSClientError.unavailable }
                #if DEBUG
                self.recordLatency("voice_until_play_seconds", since: synthesisStarted)
                if let responseStart = self.responseStartedAt {
                    self.recordLatency("after_capture_until_play_seconds", since: responseStart)
                }
                #endif
                self.state = "SPEAKING"; self.status = "SPEAKING"
                self.voiceProgress = "Reproduzindo voz natural."
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(95)) } catch { return }
                    guard let self, self.generation == id, self.audioPlayer != nil else { return }
                    self.fail("A reprodução não terminou. Voltando à espera.")
                }
            } catch {
                guard !Task.isCancelled, self.generation == id else { return }
                self.audioPlayer?.stop(); self.audioPlayer = nil
                self.voiceSource = "Voz do TARS indisponível · sem substituição"
                self.failService(error)
            }
        }
    }

    private func speakStreamed(_ text: String, isConversation: Bool = false, stream: @escaping (String, @escaping @MainActor (Data) throws -> Void) async throws -> Void) {
        speechTask?.cancel()
        let id = generation
        state = "PREPARING"; status = "PREPARING"; message = isConversation ? "TARS está preparando a resposta…" : text
        voiceSource = "Voz gerada por IA"; voiceProgress = "Preparando voz natural…"
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == id else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let player = try BufferedVoicePlayer(keepingMedia: self.keepsMediaSessionActive?() == true)
                self.streamedPlayer = player
                player.onStart = { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.state = "SPEAKING"; self.status = "SPEAKING"
                    self.voiceProgress = "Reproduzindo voz natural."
                    #if DEBUG
                    self.recordLatency(isConversation ? "first_audio_after_transcription_seconds" : "voice_until_play_seconds", since: started)
                    if let responseStart = self.responseStartedAt {
                        self.recordLatency("after_capture_until_play_seconds", since: responseStart)
                    }
                    #endif
                }
                player.onFinish = { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.completedSpeech()
                }
                self.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(95)) } catch { return }
                    guard let self, self.generation == id else { return }
                    self.fail("A reprodução não terminou. Voltando à espera.")
                }
                try await stream(text) { [weak self] data in
                    try Task.checkCancellation()
                    guard let self, self.generation == id else { throw CancellationError() }
                    try player.append(data)
                }
                guard !Task.isCancelled, self.generation == id else { return }
                try player.finishInput()
            } catch {
                guard !Task.isCancelled, self.generation == id else { return }
                let alreadyPlayed = self.streamedPlayer?.hasStarted ?? false
                self.streamedPlayer?.stop(); self.streamedPlayer = nil
                self.timeout?.cancel(); self.timeout = nil
                if isConversation {
                    self.failService(error)
                } else if alreadyPlayed {
                    self.fail("A voz foi interrompida pela conexão. Não vou repetir a resposta automaticamente.")
                } else {
                    self.voiceSource = "Voz do TARS indisponível · sem substituição"
                    self.failService(error)
                }
            }
        }
    }

    private func speakLocally(_ text: String) {
        voiceSource = "Voz sintetizada local"
        #if DEBUG
        if let simulatedOutput {
            utterance = AVSpeechUtterance(string: text)
            state = "SPEAKING"; status = "SPEAKING"
            simulatedOutput(text)
            return
        }
        #endif
        do {
            let session = AVAudioSession.sharedInstance()
            try configureVoiceOutputSession(keepingMedia: self.keepsMediaSessionActive?() == true)
            try session.setActive(true)
            let speech = AVSpeechUtterance(string: text)
            let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? language
            let voiceLanguage = detected.hasPrefix("en") ? "en" : detected.hasPrefix("pt") ? "pt" : detected
            speech.voice = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix(voiceLanguage) }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }.first
                ?? AVSpeechSynthesisVoice(language: language)
            speech.rate = 0.42
            speech.volume = 1.0
            speech.preUtteranceDelay = 0.25
            utterance = speech
            state = "PREPARING"; status = "PREPARING"
            message = text
            speaker.speak(speech)
            let id = generation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                guard let self, self.generation == id, self.utterance != nil else { return }
                self.fail("A saída de voz não concluiu. Voltando à espera.")
            }
        } catch { fail("Saída de áudio indisponível: \(error.localizedDescription)") }
    }

    func cancel(message: String = "Interação encerrada.") {
        conversationTask?.cancel(); conversationTask = nil
        speechTask?.cancel(); speechTask = nil
        audioPlayer?.stop(); audioPlayer = nil
        streamedPlayer?.stop(); streamedPlayer = nil
        stopCapture(); utterance = nil
        speaker.stopSpeaking(at: .immediate)
        state = "IDLE"; status = "IDLE"; self.message = message
        if keepsMediaSessionActive?() != true {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        scheduleListening()
    }

    private func failService(_ error: Error) {
        let failedStage = state
        if let clientError = error as? TARSClientError, clientError.blocksAutomaticVoice {
            voiceServiceBlocked = true
            handsFree = false
            restartTask?.cancel(); restartTask = nil
            trialDeadline?.cancel()
        }
        fail(error.localizedDescription)
        let code: String
        if case TARSClientError.ai(let value) = error { code = value }
        else if let network = error as? URLError { code = "URL_ERROR_\(network.code.rawValue)" }
        else { code = String(describing: type(of: error)) }
        writeVoiceDiagnostic(errorCode: code, failedStage: failedStage)
    }

    private func fail(_ message: String) {
        voiceProgress = message
        if handsFree {
            voicePolicy.failed()
            // A service/capture failure is not evidence that the speaker changed
            // language. Never switch the local recognizer after an error.
            if voicePolicy.failures >= 6 { handsFree = false }
        }
        cancel(message: message); status = "UNAVAILABLE"
    }

    private func completedSpeech() {
        if handsFree && !voicePolicy.awaitingRequest { voicePolicy.replyFinished() }
        writeVoiceDiagnostic(errorCode: nil, failedStage: "COMPLETED_SPEECH")
        voiceProgress = !handsFree ? "Resposta concluída. Escuta pausada." : voicePolicy.awaitingRequest
            ? "Pode fazer sua pergunta."
            : "Resposta concluída. Pode continuar sem dizer TARS por 30 segundos."
        cancel(message: handsFree ? "Aguardando sua voz…" : "Resposta concluída.")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.audioPlayer, ObjectIdentifier(current) == identifier else { return }
            if flag { self.completedSpeech() }
            else { self.fail("A reprodução foi interrompida. Tente uma nova pergunta.") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.audioPlayer, ObjectIdentifier(current) == identifier else { return }
            self.voiceSource = "Voz do TARS indisponível · sem substituição"
            self.fail("Falha na reprodução da voz do TARS. A resposta continua em texto.")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == identifier else { return }
            self.state = "SPEAKING"; self.status = "SPEAKING"
            self.voiceProgress = "Reproduzindo resposta em voz."
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == identifier else { return }
            self.completedSpeech()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == identifier else { return }
            self.cancel()
        }
    }
}

#if DEBUG
extension XRAudioController {
    /// Exercise production routing with a known transcript while real capture is active.
    func submitMusicProbeSpeech(_ text: String) {
        guard state == "LISTENING" else { return }
        transcript = text
        finish()
    }

    /// Bounded local-only probe; records capability/error metadata, never speech text.
    static func runLocalRecognitionProbe() async -> String {
        var lines: [String] = []
        for locale in ["pt-BR", "en-US"] {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            lines.append("\(locale): available=\(recognizer?.isAvailable ?? false), onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
            let audio = XRAudioController()
            guard !audio.onlineWake else { return "FAIL: online wake must be disabled" }
            audio.language = locale
            audio.handsFree = true
            audio.simulatedOutput = { _ in } // Probe never speaks captured content.
            await audio.start()
            for _ in 0..<100 {
                if audio.status == "UNAVAILABLE" || audio.status == "PERMISSION DENIED" { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("state=\(audio.state), status=\(audio.status)")
            if audio.status == "UNAVAILABLE" || audio.status == "PERMISSION DENIED" {
                lines.append(audio.message)
            }
            audio.suspendHandsFree()
        }
        return lines.joined(separator: "\n")
    }

    /// Runs the production routing/tasks/delegate lifecycle with only I/O replaced.
    static func runSimulatedCycleChecks() async -> String {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "VoiceCycleChecks", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<250 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(false, "Timed out waiting for voice transition")
        }
        let audio = XRAudioController()
        guard !audio.onlineWake else { return "FAIL: disable online wake for offline checks" }
        var requests: [String] = []
        var outputs: [String] = []
        var captures = 0
        audio.simulatedCapture = { captures += 1 }
        audio.simulatedOutput = { outputs.append($0) }
        audio.respond = { text, _ in
            requests.append(text)
            return text.contains("English") ? "Hello, I'm TARS." : "Olá, sou o TARS."
        }
        defer { audio.suspendHandsFree() }
        do {
            // Silent PCM uses the real AVAudioEngine completion path, no API/microphone.
            let buffered = try BufferedVoicePlayer()
            defer { buffered.stop() }
            var starts = 0
            var completions = 0
            buffered.onStart = { starts += 1 }
            buffered.onFinish = { completions += 1 }
            try buffered.append(Data(repeating: 0, count: 9600)) // 0.2 seconds
            try require(!buffered.hasStarted, "Played before prebuffer")
            try buffered.append(Data(repeating: 0, count: 28800)) // Total 0.8 seconds
            try require(buffered.hasStarted && starts == 1, "Did not start at prebuffer threshold")
            try await waitFor { buffered.rebufferCount == 1 }
            try require(completions == 0, "Network gap mistaken for end of speech")
            try buffered.append(Data(repeating: 0, count: 4800))
            try buffered.finishInput() // Final short tail must drain even below threshold.
            try await waitFor { completions == 1 }
            try require(starts == 1, "Rebuffer repeated initial callback")
            let cancelled = try BufferedVoicePlayer()
            cancelled.onFinish = { completions += 1 }
            try cancelled.append(Data(repeating: 0, count: 4800))
            cancelled.stop()
            try await Task.sleep(for: .milliseconds(100))
            try require(!cancelled.hasStarted && completions == 1, "Cancelled stream completed or played")
            try await ReferenceCameraChecks.run()
            try VoiceCameraCommandChecks.run()
            var cameraGate = ReferenceCaptureGate()
            let oldCapture = cameraGate.begin()
            cameraGate.cancel()
            try require(!cameraGate.consume(oldCapture), "Cancelled camera callback accepted")
            let replacedCapture = cameraGate.begin()
            let currentCapture = cameraGate.begin()
            try require(!cameraGate.consume(replacedCapture), "Old camera callback replaced current image")
            try require(cameraGate.consume(currentCapture) && !cameraGate.consume(currentCapture), "Camera callback not single-use")
            var visualHistories: [[[String: String]]] = []
            let context = VisualConversation { question, history in
                visualHistories.append(history)
                return "Image answer: " + question
            }
            for index in 0..<6 { _ = try await context.answer("question \(index)") }
            try require(visualHistories.map(\.count) == [0,2,4,6,8,10], "Visual history not bounded")
            do { _ = try await context.answer("over limit"); throw NSError(domain: "visual budget", code: 1) }
            catch TARSClientError.ai(let code) { try require(code == "AI_LOCAL_LIMIT", "Wrong visual limit") }
            var releaseVisual: CheckedContinuation<String, Never>?
            let cancelledContext = VisualConversation { _, _ in await withCheckedContinuation { releaseVisual = $0 } }
            let pendingVisual = Task { try await cancelledContext.answer("old image") }
            try await waitFor { releaseVisual != nil }
            cancelledContext.cancel(); releaseVisual?.resume(returning: "obsolete answer")
            do { _ = try await pendingVisual.value; throw NSError(domain: "stale visual answer", code: 1) }
            catch is CancellationError {}
            var newImageHistory: [[String: String]] = [["role":"user", "content":"sentinel"]]
            let newImage = VisualConversation { _, history in newImageHistory = history; return "New image" }
            _ = try await newImage.answer("What now?")
            try require(newImageHistory.isEmpty, "New image inherited old history")
            var visualTime: TimeInterval = 0
            let expiredVisual = VisualConversation(clock: { visualTime }) { _, _ in visualTime = 181; return "late" }
            do { _ = try await expiredVisual.answer("slow"); throw NSError(domain: "expired answer published", code: 1) }
            catch TARSClientError.ai(let code) { try require(code == "AI_LOCAL_LIMIT", "Wrong expiry error") }
            var pendingRelease: CheckedContinuation<String, Never>?
            let singleVisual = VisualConversation { _, _ in await withCheckedContinuation { pendingRelease = $0 } }
            let firstPending = Task { try await singleVisual.answer("first") }
            try await waitFor { pendingRelease != nil }
            do { _ = try await singleVisual.answer("overlap"); throw NSError(domain: "concurrent visual request", code: 1) }
            catch TARSClientError.ai(let code) { try require(code == "AI_BUSY", "Wrong overlap error") }
            pendingRelease?.resume(returning: "first answer"); _ = try await firstPending.value
            let visualAudio = XRAudioController()
            defer { visualAudio.suspendHandsFree() }
            visualAudio.simulatedCapture = {}
            var routedVisual: [String] = []
            var spokenVisual: [String] = []
            visualAudio.simulatedOutput = { spokenVisual.append($0) }
            visualAudio.respond = { _, _ in throw NSError(domain: "Visual question reached text-only AI", code: 1) }
            visualAudio.visualRespond = { question in routedVisual.append(question); return "Red square." }
            await visualAudio.enableHandsFree()
            let syntheticCapture = Data([1, 2, 3])
            let textOnlyForbidden: (String, String) async throws -> String = { _, _ in
                throw NSError(domain: "Visual question reached text-only AI", code: 1)
            }
            visualAudio.processCapturedAudio(syntheticCapture, transcribe: { data in
                try require(data == syntheticCapture, "Captured bytes changed")
                return "O que aparece nesta foto?"
            }, respond: textOnlyForbidden)
            try await waitFor { spokenVisual.count == 1 }
            guard let firstVisual = visualAudio.utterance else { throw CancellationError() }
            visualAudio.speechSynthesizer(visualAudio.speaker, didFinish: firstVisual)
            try await waitFor { visualAudio.state == "LISTENING" }
            visualAudio.processCapturedAudio(syntheticCapture, transcribe: { _ in "What color is it?" }, respond: textOnlyForbidden)
            try await waitFor { spokenVisual.count == 2 }
            try require(routedVisual == ["O que aparece nesta foto?", "What color is it?"], "Explicit visual conversation must accept either language without wake")
            visualAudio.suspendHandsFree()
            visualAudio.visualRespond = nil
            await visualAudio.enableHandsFree()
            visualAudio.transcript = "Unrelated ambient speech"
            visualAudio.finish()
            try require(routedVisual.count == 2 && spokenVisual.count == 2, "Stopping visual conversation must restore wake gating")
            let vision = XRAudioController()
            defer { vision.suspendHandsFree() }
            var visionOutputs: [String] = []
            var visionCaptures = 0
            vision.simulatedOutput = { visionOutputs.append($0) }
            vision.simulatedCapture = { visionCaptures += 1 }
            vision.speakVisionDescription("Quadrado vermelho à esquerda.")
            try require(visionOutputs.count == 1 && !vision.handsFree && vision.useAI, "Vision must use approved voice without listening")
            guard let visualUtterance = vision.utterance else { throw CancellationError() }
            vision.speechSynthesizer(vision.speaker, didFinish: visualUtterance)
            try await Task.sleep(for: .milliseconds(100))
            try require(visionCaptures == 0 && vision.state == "IDLE", "Vision completion started microphone")
            vision.speakVisionDescription("Blue circle on the right.")
            vision.suspendHandsFree()
            try require(vision.state == "IDLE" && vision.utterance == nil, "Vision cancellation failed")
            vision.speakVisionDescription("  ")
            try require(visionOutputs.count == 2, "Empty vision response was spoken")
            let early = XRAudioController()
            defer { early.suspendHandsFree() }
            early.simulatedCapture = {}
            var wrongFallback: [String] = []
            early.simulatedOutput = { wrongFallback.append($0) }
            await early.enableHandsFree()
            early.stopCapture()
            early.speakStreamed("question must never be spoken", isConversation: true) { _, receive in
                try receive(Data(repeating: 0, count: 38400))
                try await Task.sleep(for: .milliseconds(100))
                try receive(Data(repeating: 0, count: 19200))
            }
            try await waitFor { early.voicePolicy.acceptsFollowUp() }
            try require(wrongFallback.isEmpty, "Pipeline echoed the question")
            early.suspendHandsFree()
            await early.enableHandsFree()
            early.stopCapture()
            early.speakStreamed("never repeat this question", isConversation: true) { _, _ in
                throw TARSClientError.pairingRejected
            }
            try await waitFor { early.voiceServiceBlocked }
            try require(wrongFallback.isEmpty, "Failed pipeline spoke user input")
            await audio.enableHandsFree()
            try require(audio.state == "LISTENING", "Initial listening")
            audio.transcript = "conversa ambiente"
            audio.finish()
            try await waitFor { audio.state == "LISTENING" }
            try require(requests.isEmpty && outputs.isEmpty, "Ambient speech reached response")
            try require(audio.lastHeard == "conversa ambiente" && audio.voiceProgress.contains("não identifiquei"),
                        "Ignored wake must retain useful feedback")

            audio.transcript = "Ei TARS"
            audio.finish()
            try require(audio.state == "SPEAKING" && audio.voicePolicy.awaitingRequest,
                        "Wake must acknowledge and await question")
            guard let ack = audio.utterance else { throw CancellationError() }
            audio.speechSynthesizer(audio.speaker, didFinish: ack)
            try await waitFor { audio.state == "LISTENING" }
            audio.transcript = "me responda em português"
            audio.finish()
            try await waitFor { audio.state == "SPEAKING" }
            try require(requests == ["me responda em português"] && outputs.last == "Olá, sou o TARS.",
                        "Portuguese request/answer mismatch")
            guard let portuguese = audio.utterance else { throw CancellationError() }
            audio.speechSynthesizer(audio.speaker, didFinish: portuguese)
            try await waitFor { audio.state == "LISTENING" }
            try require(!audio.voicePolicy.awaitingRequest, "Question authorization leaked into next cycle")

            audio.transcript = "e pode continuar em português?"
            audio.finish()
            try await waitFor { audio.state == "SPEAKING" }
            try require(requests.count == 2 && requests.last == "e pode continuar em português?",
                        "Follow-up without wake word was ignored")
            guard let followUp = audio.utterance else { throw CancellationError() }
            audio.speechSynthesizer(audio.speaker, didFinish: followUp)
            try await waitFor { audio.state == "LISTENING" }

            audio.transcript = "TARS, answer me in English"
            audio.finish()
            try await waitFor { audio.state == "SPEAKING" }
            try require(requests.count == 3 && outputs.last == "Hello, I'm TARS.", "English request/answer mismatch")
            guard let english = audio.utterance else { throw CancellationError() }
            // An old completion must not cancel the current utterance.
            audio.speechSynthesizer(audio.speaker, didFinish: portuguese)
            try await Task.sleep(for: .milliseconds(30))
            try require(audio.state == "SPEAKING", "Stale speech callback cancelled new answer")
            audio.speechSynthesizer(audio.speaker, didFinish: english)
            try await waitFor { audio.state == "LISTENING" }

            var delayed: CheckedContinuation<String, Never>?
            audio.respond = { text, _ in
                requests.append(text)
                return await withCheckedContinuation { delayed = $0 }
            }
            audio.transcript = "TARS, pergunta interrompida"
            audio.finish()
            try await waitFor { delayed != nil }
            let outputCount = outputs.count
            audio.suspendHandsFree()
            delayed?.resume(returning: "This cancelled answer must never play")
            delayed = nil
            try await Task.sleep(for: .milliseconds(750))
            try require(audio.state == "IDLE" && outputs.count == outputCount,
                        "Cancelled response played or restarted capture")
            await audio.enableHandsFree()
            audio.transcript = "fala sem nova ativação"
            audio.finish()
            try await waitFor { audio.state == "LISTENING" }
            try require(requests.count == 4, "Cancelled request was replayed")

            audio.respond = { _, _ in throw TARSClientError.pairingRejected }
            audio.transcript = "TARS, nova pergunta"
            audio.finish()
            try await waitFor { audio.voiceServiceBlocked }
            let stoppedCaptures = captures
            await audio.enableHandsFree()
            try await Task.sleep(for: .milliseconds(750))
            try require(audio.state == "IDLE" && captures == stoppedCaptures,
                        "Permanent failure restarted capture")
            let natural = XRAudioController()
            defer { natural.suspendHandsFree() }
            natural.simulatedCapture = {}
            natural.testNaturalVoice = true
            var fallback: [String] = []
            natural.simulatedOutput = { fallback.append($0) }
            var generations = 0
            // A short silent WAV exercises AVAudioPlayer and its real completion delegate.
            var fixture = Data([82,73,70,70,100,31,0,0,87,65,86,69,102,109,116,32,
                                16,0,0,0,1,0,1,0,128,62,0,0,0,125,0,0,2,0,16,0,
                                100,97,116,97,64,31,0,0])
            fixture.append(Data(repeating: 0, count: 8000))
            natural.synthesize = { _ in generations += 1; return fixture }
            await natural.enableHandsFree()
            natural.stopCapture()
            natural.speak("Resposta natural")
            try await waitFor { natural.voicePolicy.acceptsFollowUp() }
            try require(generations == 1 && fallback.isEmpty, "Natural playback did not finish normally")
            natural.suspendHandsFree()
            var pendingAudio: CheckedContinuation<Data, Never>?
            natural.synthesize = { _ in await withCheckedContinuation { pendingAudio = $0 } }
            await natural.enableHandsFree()
            natural.stopCapture()
            natural.speak("Resposta cancelada")
            try await waitFor { pendingAudio != nil }
            natural.suspendHandsFree()
            pendingAudio?.resume(returning: fixture); pendingAudio = nil
            try await Task.sleep(for: .milliseconds(50))
            try require(natural.audioPlayer == nil && fallback.isEmpty, "Cancelled audio played")
            natural.synthesize = { _ in generations += 1; throw TARSClientError.unavailable }
            await natural.enableHandsFree()
            natural.stopCapture()
            natural.speak("Alternativa local")
            try await waitFor { natural.status == "UNAVAILABLE" }
            try require(generations == 2 && fallback.isEmpty, "Failed natural speech must not substitute local voice")
            natural.suspendHandsFree()
            natural.synthesize = { _ in generations += 1; return fixture }
            await natural.enableHandsFree()
            natural.stopCapture()
            natural.speak("Nova resposta com a voz aprovada")
            try await waitFor { natural.voicePolicy.acceptsFollowUp() }
            try require(generations == 3 && fallback.isEmpty, "A new response must recover the approved voice")
            return "PASS: camera permissions/unavailable/disconnect, photo normalization, delegate completion; camera cancellation/replacement/single-use; image replacement, expiry during response, overlapping request rejection; visual dialogue routing PT/EN, bounded history/budget, cancelled context; early response drain, no question echo, permanent failure stop; PCM prebuffer, underrun recovery, final drain, cancellation; natural playback completion, cancelled audio, no silent voice substitution, recovery on new response; controller cycle PT/EN, ambient ignore, wake-only, return to wake, stale callback, cancelled answer, no replay, permanent failure pause. Simulated I/O; no microphone, TTS output or API."
        } catch {
            return "FAIL: " + error.localizedDescription
        }
    }
}
#endif


/// One continuous PCM timeline, with prebuffering and bounded rebuffering.
@MainActor
private final class BufferedVoicePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var queuedFrames = 0
    private var totalFrames = 0
    private var finished = false
    private var stopped = false
    private var threshold = 19200 // 0.8 seconds, increased after an underrun.
    private(set) var hasStarted = false
    private(set) var rebufferCount = 0
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    init(keepingMedia: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        try configureVoiceOutputSession(keepingMedia: keepingMedia)
        try session.setActive(true)
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare(); try engine.start()
    }
    func append(_ data: Data) throws {
        guard !stopped, !finished, !data.isEmpty, data.count % 2 == 0 else { throw TARSClientError.unavailable }
        let count = data.count / 2
        totalFrames += count
        guard totalFrames <= 2_160_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.floatChannelData?[0] else { throw TARSClientError.unavailable }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                let value = UInt16(bytes[2*i]) | (UInt16(bytes[2*i+1]) << 8)
                samples[i] = Float(Int16(bitPattern: value)) / 32768
            }
        }
        queuedFrames += count
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.consumed(count) }
        }
        resumeIfReady()
    }
    func finishInput() throws {
        guard !stopped, totalFrames > 0 else { throw TARSClientError.unavailable }
        finished = true
        if queuedFrames == 0 { complete() } else { resumeIfReady() }
    }
    private func resumeIfReady() {
        guard !stopped, !node.isPlaying, queuedFrames > 0,
              finished || queuedFrames >= threshold else { return }
        node.play()
        if !hasStarted { hasStarted = true; onStart?() }
    }
    private func consumed(_ count: Int) {
        guard !stopped else { return }
        queuedFrames -= count
        if queuedFrames == 0 {
            if finished { complete() }
            else { node.pause(); threshold = 38400; rebufferCount += 1 }
        }
    }
    private func complete() {
        let callback = onFinish
        stop(); callback?()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; onStart = nil; onFinish = nil
        node.stop(); engine.stop(); queuedFrames = 0
    }
}

/// Keep the microphone/music route stable when TARS speaks over an open player.
@MainActor
private func configureVoiceOutputSession(keepingMedia: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    if keepingMedia {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
        if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(.playAndRecord, mode: .default, options: options)
        }
    } else {
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }
}
