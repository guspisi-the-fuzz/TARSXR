import AVFoundation
import Speech
import Combine
import NaturalLanguage
import UIKit

@MainActor
final class XRAudioController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var state = "IDLE"
    @Published private(set) var status = "NOT ENABLED"
    @Published private(set) var transcript = ""
    @Published private(set) var message = "Diga TARS para conversar quando a escuta estiver disponível."
    @Published private(set) var level: Double = 0
    @Published private(set) var inputName = ""
    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
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
    private var lastVoice = Date()
    private var utterance: AVSpeechUtterance?
    private var interruption: NSObjectProtocol?
    private var handsFree = false
    private var resumeAfterInterruption = false
    private var voicePolicy = VoiceActivationPolicy()
    private var restartTask: Task<Void, Never>?
    private var onlineTrial = OnlineVoiceTrialBudget()
    private var trialDeadline: Task<Void, Never>?

    private func endOnlineTrial() {
        suspendHandsFree()
        status = "TRIAL FINISHED"
        message = "Teste online encerrado: limite de 3 minutos ou 6 envios."
    }

    func enableHandsFree() async {
        guard !handsFree else { return }
        if onlineWake {
            onlineTrial.begin(now: ProcessInfo.processInfo.systemUptime)
            guard onlineTrial.available(now: ProcessInfo.processInfo.systemUptime) else {
                endOnlineTrial(); return
            }
            if trialDeadline == nil {
                trialDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
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
            transcript = ""; level = 0; lastVoice = Date()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                req.append(buffer)
                let amplitude = Self.amplitude(buffer)
                Task { @MainActor in
                    guard let self, self.generation == id, self.state == "LISTENING" else { return }
                    self.level = self.level * 0.25 + amplitude * 0.75
                    if amplitude > 0.08 { self.lastVoice = Date() }
                }
            }
            tapInstalled = true
            state = "LISTENING"; status = "LISTENING"
            status = handsFree && !voicePolicy.awaitingRequest ? "WAITING_WAKE" : "LISTENING"
            message = handsFree
                ? (voicePolicy.awaitingRequest ? "Estou ouvindo. Pode falar." : "Diga TARS para conversar.")
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
                        let selectedLanguage = self.language == "en-US" ? "inglês" : "português"
                        self.fail("Reconhecimento em \(selectedLanguage) indisponível (\(failureCode)). O teste local está indisponível. Tente novamente.")
                    }
                }
            }
            engine.prepare(); try engine.start()
            timeout = Task { [weak self] in
                let began = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, let self, self.generation == id,
                          self.state == "LISTENING" else { return }
                    let silence = Date().timeIntervalSince(self.lastVoice)
                    if (!self.transcript.isEmpty && silence > 2.4) || Date().timeIntervalSince(began) > 20 {
                        self.finish(); return
                    }
                    if self.transcript.isEmpty && Date().timeIntervalSince(began) > 15 {
                        if self.handsFree { self.voicePolicy.reset() }
                        self.cancel(message: self.handsFree ? "Diga TARS para conversar." : "Não ouvi uma frase."); return
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
            transcript = ""; level = 0; lastVoice = Date()
            state = "LISTENING"; status = "LISTENING"
            status = handsFree && !voicePolicy.awaitingRequest ? "WAITING_WAKE_ONLINE" : "LISTENING"
            message = handsFree && !voicePolicy.awaitingRequest
                ? "Escuta online · PT/EN · diga TARS / say TARS"
                : "Pode falar em português ou inglês / Speak Portuguese or English."
            timeout = Task { [weak self] in
                let began = Date()
                var heardVoice = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.generation == id,
                          self.state == "LISTENING", let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let power = Double(recorder.averagePower(forChannel: 0))
                    self.level = min(1, max(0, (power + 55) / 45))
                    if power > -40 { self.lastVoice = Date(); heardVoice = true }
                    let elapsed = Date().timeIntervalSince(began)
                    if heardVoice && (Date().timeIntervalSince(self.lastVoice) > 2.4 || elapsed > 20) {
                        self.finish(); return
                    }
                    if !heardVoice && elapsed > 15 {
                        if self.handsFree { self.voicePolicy.reset() }
                        self.cancel(message: self.handsFree ? "Aguardando TARS / Waiting for TARS" : "Não detectei fala."); return
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
        state = "TRANSCRIBING"; status = "TRANSCRIBING"
        message = "Entendendo sua fala…"
        conversationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.handsFree && self.onlineWake {
                    guard self.onlineTrial.reserveUpload(now: ProcessInfo.processInfo.systemUptime) else {
                        self.endOnlineTrial(); return
                    }
                }
                let text = try await transcribe(data)
                guard !Task.isCancelled, self.generation == id else { return }
                guard let request = self.routeRecognizedSpeech(text) else { return }
                self.transcript = request
                self.state = "THINKING"; self.status = "THINKING"
                self.message = "TARS está pensando…"
                let answer = try await respond(request, "auto")
                guard !Task.isCancelled, self.generation == id else { return }
                self.speak(answer)
            } catch {
                guard !Task.isCancelled, self.generation == id else { return }
                self.fail(error.localizedDescription)
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
                guard let self else { return }
                do {
                    let answer = try await respond(text, self.language)
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.speak(answer)
                } catch {
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.fail(error.localizedDescription)
                }
            }
            return
        }
        let prefix = language == "en-US" ? "You said" : "Você disse"
        let spoken = AudioTestPronunciation.spokenText(text, language: language)
        speak("\(prefix): \(String(spoken.prefix(120)))")
    }

    private func routeRecognizedSpeech(_ text: String) -> String? {
        guard handsFree else { return text }
        switch voicePolicy.consume(text) {
        case .ignore:
            transcript = ""
            cancel(message: "Aguardando TARS / Waiting for TARS")
            return nil
        case .acknowledge:
            speak("Estou ouvindo. I'm listening.")
            return nil
        case .request(let request):
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
        stopCapture(); utterance = nil
        speaker.stopSpeaking(at: .immediate)
        state = "IDLE"; status = "IDLE"; self.message = message
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        scheduleListening()
    }

    private func fail(_ message: String) {
        if handsFree {
            voicePolicy.failed()
            if !onlineWake { language = language == "pt-BR" ? "en-US" : "pt-BR" }
            if voicePolicy.failures >= 6 { handsFree = false }
        }
        cancel(message: message); status = "UNAVAILABLE"
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == identifier else { return }
            self.state = "SPEAKING"; self.status = "SPEAKING"
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let current = self.utterance, ObjectIdentifier(current) == identifier else { return }
            self.cancel(message: self.handsFree ? "Aguardando sua voz…" : "Resposta concluída.")
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
