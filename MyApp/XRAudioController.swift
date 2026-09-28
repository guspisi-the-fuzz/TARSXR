import AVFoundation
import Speech
import Combine
import NaturalLanguage
import UIKit

@MainActor
final class XRAudioController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var state = "IDLE"
    @Published private(set) var status = "NOT ENABLED"
    @Published private(set) var transcript = ""
    @Published private(set) var lastHeard = ""
    @Published private(set) var voiceProgress = ""
    @Published private(set) var message = "Diga TARS para conversar quando a escuta estiver disponível."
    @Published private(set) var level: Double = 0
    @Published private(set) var inputName = ""
    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    var streamSpeech: ((String, @escaping @MainActor (Data) throws -> Void) async throws -> Void)?
    private var streamedPlayer: BufferedVoicePlayer?
    private let streamingEnabled = ProcessInfo.processInfo.environment["TARS_STREAM_VOICE"] == "1"
    var synthesize: ((String) async throws -> Data)?
    @Published private(set) var voiceSource = "Voz sintetizada local"
    private var speechTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var naturalVoiceUnavailable = false
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
    var respond: ((String, String) async throws -> String)?
    @Published var useAI = false
    private var tapInstalled = false
    private var generation = UUID()
    private var captureWindow = VoiceCaptureWindow(now: ProcessInfo.processInfo.systemUptime)
    private var utterance: AVSpeechUtterance?
    private var interruption: NSObjectProtocol?
    private var handsFree = false
    private var voiceServiceBlocked = false
    private var resumeAfterInterruption = false
    private var voicePolicy = VoiceActivationPolicy()
    private var restartTask: Task<Void, Never>?
    private var onlineTrial = OnlineVoiceTrialBudget(conversation: ProcessInfo.processInfo.environment["TARS_VOICE_SESSION"] == "conversation")
    private var trialDeadline: Task<Void, Never>?
    #if DEBUG && targetEnvironment(simulator)
    // Explicit diagnostic injection; absent from release and normal launches.
    private var simulatedCapture: (() -> Void)?
    private var simulatedOutput: ((String) -> Void)?
    private var testNaturalVoice = false
    private var voiceLatency: [String: Double] = [:]
    private func recordLatency(_ stage: String, since start: TimeInterval) {
        voiceLatency[stage] = ProcessInfo.processInfo.systemUptime - start
        guard let data = try? JSONSerialization.data(withJSONObject: voiceLatency, options: [.sortedKeys]) else { return }
        // Overwrite only the latest timings. Never persist speech, text or credentials.
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("voice-latency.json"), options: .atomic)
    }

    #endif

    private func endOnlineTrial() {
        suspendHandsFree()
        status = "TRIAL FINISHED"
        message = "Sessão online encerrada: \(onlineTrial.uploads) de \(onlineTrial.maxUploads) envios; limite de \(Int(onlineTrial.duration / 60)) minutos."
    }

    func enableHandsFree() async {
        guard !handsFree, !voiceServiceBlocked else { return }
        if onlineWake {
            onlineTrial.begin(now: ProcessInfo.processInfo.systemUptime)
            guard onlineTrial.available(now: ProcessInfo.processInfo.systemUptime) else {
                endOnlineTrial(); return
            }
            if trialDeadline == nil {
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
        handsFree = false
        restartTask?.cancel(); restartTask = nil
        voicePolicy.reset()
        cancel(message: "Escuta pausada fora do app ou durante interrupção.")
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
        speaker.delegate = self
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let self else { return }
            Task { @MainActor in
                if value == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.handsFree
                    self.suspendHandsFree()
                } else if self.resumeAfterInterruption && UIApplication.shared.applicationState == .active {
                    self.resumeAfterInterruption = false
                    await self.enableHandsFree()
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
        #if DEBUG && targetEnvironment(simulator)
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
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
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
            req.contextualStrings = ["TARS"]
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
                    if let text { self.transcript = text }
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
                        if self.handsFree { self.voicePolicy.reset() }
                        if self.handsFree && !self.voicePolicy.awaitingRequest {
                self.voicePolicy.replyFinished()
            }
            self.voiceProgress = "Resposta concluída. Pode continuar sem dizer TARS por 30 segundos."
            self.cancel(message: self.handsFree ? "Diga TARS para conversar." : "Não ouvi uma frase.")
                        return
                    case .keepListening: break
                    }
                }
            }
        } catch { fail("Não foi possível iniciar o áudio: \(error.localizedDescription)") }
    }

    private func startMultilingualCapture(id: UUID) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
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
            let followUp = voicePolicy.acceptsFollowUp()
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
                    if power > -40 { self.captureWindow.observeVoice(now: ProcessInfo.processInfo.systemUptime) }
                    switch self.captureWindow.decision(now: ProcessInfo.processInfo.systemUptime) {
                    case .finish: self.finish(); return
                    case .discard:
                        if self.handsFree { self.voicePolicy.reset() }
                        if self.handsFree && !self.voicePolicy.awaitingRequest {
                self.voicePolicy.replyFinished()
            }
            self.voiceProgress = "Resposta concluída. Pode continuar sem dizer TARS por 30 segundos."
            self.cancel(message: self.handsFree ? "Aguardando TARS / Waiting for TARS" : "Não detectei fala.")
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
        stopCapture()
        let id = generation
        let capturedAt = ProcessInfo.processInfo.systemUptime
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
                self.voiceProgress = "Transcrevendo · envio \(self.onlineTrial.uploads)/\(self.onlineTrial.maxUploads)"
                #if DEBUG && targetEnvironment(simulator)
                self.voiceLatency = [:]
                let transcriptionStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let text = try await transcribe(data)
                guard !Task.isCancelled, self.generation == id else { return }
                #if DEBUG && targetEnvironment(simulator)
                self.recordLatency("transcription_seconds", since: transcriptionStarted)
                #endif
                guard let request = self.routeRecognizedSpeech(text, capturedAt: capturedAt) else { return }
                self.transcript = request
                self.state = "THINKING"; self.status = "THINKING"
                self.message = "TARS está pensando…"
                self.voiceProgress = "Pergunta reconhecida; aguardando resposta da IA."
                #if DEBUG && targetEnvironment(simulator)
                let answerStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let answer = try await respond(request, "auto")
                guard !Task.isCancelled, self.generation == id else { return }
                #if DEBUG && targetEnvironment(simulator)
                self.recordLatency("answer_seconds", since: answerStarted)
                #endif
                self.speak(answer)
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
        guard let text = routeRecognizedSpeech(recognized) else { return }
        guard !text.isEmpty else { cancel(message: "Nenhuma fala reconhecida."); return }
        if useAI {
            guard let respond else { fail("A conexão com a IA ainda não está pronta."); return }
            let id = generation
            state = "THINKING"; status = "THINKING"
            message = "TARS está pensando…"
            conversationTask = Task { [weak self] in
                guard let self, !Task.isCancelled, self.generation == id else { return }
                do {
                    let answer = try await respond(text, self.language)
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.speak(answer)
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

    private func routeRecognizedSpeech(_ text: String, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        lastHeard = String(text.prefix(300))
        guard handsFree else { return text }
        switch voicePolicy.consume(text, now: capturedAt) {
        case .ignore:
            voiceProgress = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Nenhuma fala reconhecida."
                : "Transcrição recebida, mas não identifiquei TARS."
            transcript = ""
            cancel(message: "Aguardando TARS / Waiting for TARS")
            return nil
        case .acknowledge:
            voiceProgress = "TARS reconhecido; aguardando sua pergunta após a confirmação."
            speak("Estou ouvindo. I'm listening.")
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

    private func speak(_ text: String) {
        #if DEBUG && targetEnvironment(simulator)
        if simulatedOutput != nil && !testNaturalVoice { speakLocally(text); return }
        #endif
        guard useAI, !naturalVoiceUnavailable, let synthesize else { speakLocally(text); return }
        if streamingEnabled, let streamSpeech {
            speakStreamed(text, stream: streamSpeech)
            return
        }
        speechTask?.cancel()
        let id = generation
        state = "PREPARING"; status = "PREPARING"
        message = text
        voiceSource = "Voz gerada por IA"
        voiceProgress = "Preparando voz natural…"
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == id else { return }
            do {
                #if DEBUG && targetEnvironment(simulator)
                let synthesisStarted = ProcessInfo.processInfo.systemUptime
                #endif
                let data = try await synthesize(text)
                guard !Task.isCancelled, self.generation == id else { return }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(data: data)
                guard player.duration > 0, player.duration <= 90 else { throw TARSClientError.unavailable }
                self.audioPlayer = player
                player.delegate = self
                guard player.play() else { throw TARSClientError.unavailable }
                #if DEBUG && targetEnvironment(simulator)
                self.recordLatency("voice_until_play_seconds", since: synthesisStarted)
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
                self.naturalVoiceUnavailable = true
                self.voiceProgress = "Voz natural indisponível; usando a voz local nesta sessão."
                self.speakLocally(text)
            }
        }
    }

    private func speakStreamed(_ text: String, stream: @escaping (String, @escaping @MainActor (Data) throws -> Void) async throws -> Void) {
        speechTask?.cancel()
        let id = generation
        state = "PREPARING"; status = "PREPARING"; message = text
        voiceSource = "Voz gerada por IA"; voiceProgress = "Preparando voz natural…"
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == id else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let player = try BufferedVoicePlayer()
                self.streamedPlayer = player
                player.onStart = { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.state = "SPEAKING"; self.status = "SPEAKING"
                    self.voiceProgress = "Reproduzindo voz natural."
                    #if DEBUG && targetEnvironment(simulator)
                    self.recordLatency("voice_until_play_seconds", since: started)
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
                self.naturalVoiceUnavailable = true
                self.timeout?.cancel(); self.timeout = nil
                if alreadyPlayed {
                    self.fail("A voz foi interrompida pela conexão. Não vou repetir a resposta automaticamente.")
                } else {
                    self.speakLocally(text)
                }
            }
        }
    }

    private func speakLocally(_ text: String) {
        voiceSource = naturalVoiceUnavailable ? "Voz local · alternativa ativa" : "Voz sintetizada local"
        #if DEBUG && targetEnvironment(simulator)
        if let simulatedOutput {
            utterance = AVSpeechUtterance(string: text)
            state = "SPEAKING"; status = "SPEAKING"
            simulatedOutput(text)
            return
        }
        #endif
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        scheduleListening()
    }

    private func failService(_ error: Error) {
        if let clientError = error as? TARSClientError, clientError.blocksAutomaticVoice {
            voiceServiceBlocked = true
            handsFree = false
            restartTask?.cancel(); restartTask = nil
            trialDeadline?.cancel()
        }
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        voiceProgress = message
        if handsFree {
            voicePolicy.failed()
            if !onlineWake { language = language == "pt-BR" ? "en-US" : "pt-BR" }
            if voicePolicy.failures >= 6 { handsFree = false }
        }
        cancel(message: message); status = "UNAVAILABLE"
    }

    private func completedSpeech() {
        if handsFree && !voicePolicy.awaitingRequest { voicePolicy.replyFinished() }
        voiceProgress = voicePolicy.awaitingRequest
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
            self.naturalVoiceUnavailable = true
            self.fail("Falha na reprodução. A próxima resposta usará a voz local.")
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

#if DEBUG && targetEnvironment(simulator)
extension XRAudioController {
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
            try await waitFor { fallback.count == 1 }
            natural.cancel()
            natural.speak("Sem repetir chamada paga")
            try require(generations == 2 && fallback.count == 2, "Fallback retried paid generation")
            return "PASS: PCM prebuffer, underrun recovery, final drain, cancellation; natural playback completion, cancelled audio, bounded local fallback; controller cycle PT/EN, ambient ignore, wake-only, return to wake, stale callback, cancelled answer, no replay, permanent failure pause. Simulated I/O; no microphone, TTS output or API."
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

    init() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
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
