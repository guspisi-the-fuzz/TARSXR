import AVFoundation
import Speech
import Combine

@MainActor
final class XRAudioController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var state = "IDLE"
    @Published private(set) var status = "NOT ENABLED"
    @Published private(set) var transcript = ""
    @Published private(set) var message = "Toque em Falar para ativar o microfone."
    @Published private(set) var level: Double = 0
    @Published private(set) var inputName = ""
    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    @Published var language = "pt-BR"
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

    override init() {
        super.init()
        speaker.delegate = self
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue, let self else { return }
            Task { @MainActor in self.cancel(message: "Áudio interrompido. Toque em Falar para retomar.") }
        }
    }

    func start() async {
        guard state == "IDLE" else { return }
        generation = UUID()
        let id = generation
        state = "AUTHORIZING"
        message = "Aguardando permissão de microfone e reconhecimento."
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard id == generation else { return }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard id == generation else { return }
        guard speech == .authorized, mic else {
            state = "IDLE"; status = "PERMISSION DENIED"
            message = "Permita microfone e reconhecimento nos Ajustes para falar."
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        guard let recognizer, recognizer.isAvailable else {
            fail("Reconhecimento de voz indisponível. Tente novamente."); return
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
            message = "Estou ouvindo… pause ao terminar ou toque em Concluir."
            recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.generation == id, self.state == "LISTENING" else { return }
                    if let text { self.transcript = text }
                    if final { self.finish() }
                    else if failed { self.fail("Não consegui reconhecer a fala. Tente novamente.") }
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
                        self.cancel(message: "Não ouvi uma frase. Toque em Falar para tentar novamente."); return
                    }
                }
            }
        } catch { fail("Não foi possível iniciar o áudio: \(error.localizedDescription)") }
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
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); recognition?.cancel()
        request = nil; recognition = nil; level = 0
    }

    func finish() {
        guard state == "LISTENING" else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopCapture()
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
            speech.voice = AVSpeechSynthesisVoice(language: language)
            speech.rate = 0.42
            speech.volume = 1.0
            speech.preUtteranceDelay = 0.25
            utterance = speech
            state = "PREPARING"; status = "PREPARING"
            message = text
            speaker.speak(speech)
        } catch { fail("Saída de áudio indisponível: \(error.localizedDescription)") }
    }

    func cancel(message: String = "Áudio cancelado. Toque em Falar para retomar.") {
        conversationTask?.cancel(); conversationTask = nil
        stopCapture(); utterance = nil
        speaker.stopSpeaking(at: .immediate)
        state = "IDLE"; status = "IDLE"; self.message = message
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
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
            self.cancel(message: "Confira abaixo o que foi reconhecido. Toque em Falar para repetir.")
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
