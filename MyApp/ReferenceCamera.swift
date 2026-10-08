import SwiftUI
import UIKit
import AVFoundation

/// One explicit still-photo capture. No recording, library save or network access.
struct ReferenceCamera: UIViewControllerRepresentable {
    let complete: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var completed = false
        let complete: (UIImage?) -> Void
        init(complete: @escaping (UIImage?) -> Void) { self.complete = complete }
        private func finish(_ image: UIImage?) {
            guard !completed else { return }
            completed = true; complete(image)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish(info[.originalImage] as? UIImage)
        }
    }
}

/// Reject callbacks from a cancelled or replaced capture, including permission waits.
struct ReferenceCaptureGate {
    private(set) var ticket: UUID?
    mutating func begin() -> UUID { let id = UUID(); ticket = id; return id }
    mutating func cancel() { ticket = nil }
    func accepts(_ id: UUID) -> Bool { ticket == id }
    mutating func consume(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        ticket = nil; return true
    }
}

@MainActor
enum ReferenceCameraAccess {
    enum Result { case ready, unavailable, denied }
    static func check(available: () -> Bool = { UIImagePickerController.isSourceTypeAvailable(.camera) },
                      status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
                      request: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }) async -> Result {
        guard available() else { return .unavailable }
        let allowed: Bool
        switch status() {
        case .authorized: allowed = true
        case .notDetermined: allowed = await request()
        default: allowed = false
        }
        guard allowed else { return .denied }
        return available() ? .ready : .unavailable
    }
}

@MainActor
enum ReferencePhoto {
    static func normalize(_ input: UIImage) -> (image: UIImage, png: Data)? {
        let width = input.size.width, height = input.size.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = min(1, 480 / max(width, height))
        let size = CGSize(width: max(1, floor(width*ratio)), height: max(1, floor(height*ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.preferredRange = .standard; format.opaque = true
        let clean = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            input.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = clean.pngData(), png.count <= 1_000_000 else { return nil }
        return (clean, png)
    }
}

// MARK: - XR_VOICE_CAMERA_28

enum VoiceCameraError: LocalizedError {
    case unavailable
    case denied
    case invalidImage
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Câmera indisponível neste XR."
        case .denied:
            return "Câmera não autorizada. Permita o acesso à câmera nos Ajustes do iOS."
        case .invalidImage:
            return "Capturei a imagem, mas não consegui prepará-la para análise."
        case .captureFailed:
            return "Não consegui capturar a imagem agora."
        }
    }
}

struct VoiceCameraCommand: Equatable {
    enum Kind: Equatable {
        case describe
        case findMel
        case photo
        case selfie
    }

    let kind: Kind
    let position: AVCaptureDevice.Position
    let source: String
    let question: String

    static func parse(_ raw: String) -> VoiceCameraCommand? {
        let text = normalize(raw)
        guard !text.isEmpty else { return nil }

        let mentionsVision =
            text.contains("camera") ||
            text.contains("foto") ||
            text.contains("selfie") ||
            text.contains("vendo") ||
            text.contains("ve ") ||
            text.contains("ver ") ||
            text.contains("olha") ||
            text.contains("olhe") ||
            text.contains("procura") ||
            text.contains("procurar") ||
            text.contains("ache") ||
            text.contains("encontre") ||
            text.contains("mel")

        guard mentionsVision else { return nil }

        if text.contains("selfie") || text.contains("minha cara") || text.contains("meu rosto") {
            return VoiceCameraCommand(
                kind: .selfie,
                position: .front,
                source: "reference",
                question: "Analise esta selfie capturada pela câmera frontal do XR. Descreva objetivamente o que aparece, sem inventar identidade ou detalhes fora da imagem."
            )
        }

        if (text.contains("mel") && (
            text.contains("procura") ||
            text.contains("procurar") ||
            text.contains("ache") ||
            text.contains("acha") ||
            text.contains("encontre") ||
            text.contains("cade") ||
            text.contains("onde esta") ||
            text.contains("onde ta") ||
            text.contains("vendo") ||
            text.contains("ve")
        )) {
            return VoiceCameraCommand(
                kind: .findMel,
                position: .back,
                source: "reference",
                question: "Analise esta imagem da câmera traseira do XR e diga se há uma gata visível que possa ser a Mel. Seja objetivo: diga se encontrou, onde ela parece estar na imagem e o nível de confiança. Não afirme que é a Mel se não houver gato visível."
            )
        }

        // Voice camera V28C parser expansion: commands like
        // “abre a câmera” must capture and describe instead of falling through to generic AI.
        if text.contains("abre a camera") ||
            text.contains("abre camera") ||
            text.contains("abrir a camera") ||
            text.contains("abrir camera") ||
            text.contains("liga a camera") ||
            text.contains("liga camera") ||
            text.contains("ativa a camera") ||
            text.contains("ativa camera") ||
            text.contains("ative a camera") ||
            text.contains("ative camera") ||
            text.contains("usa a camera") ||
            text.contains("use a camera") {
            return VoiceCameraCommand(
                kind: .describe,
                position: .back,
                source: "reference",
                question: "Descreva objetivamente o que aparece nesta imagem capturada pela câmera traseira do XR. Não estime distâncias métricas e não assuma movimento ou navegação."
            )
        }

        if text.contains("o que voce esta vendo") ||
            text.contains("o que voce ta vendo") ||
            text.contains("o que vc esta vendo") ||
            text.contains("o que vc ta vendo") ||
            text.contains("o que ce esta vendo") ||
            text.contains("o que ce ta vendo") ||
            text.contains("o que esta vendo") ||
            text.contains("o que ta vendo") ||
            text.contains("que que voce esta vendo") ||
            text.contains("que que voce ta vendo") ||
            text.contains("que que ta vendo") ||
            text.contains("o que voce ve") ||
            text.contains("o que vc ve") ||
            text.contains("o que ce ve") ||
            text.contains("o que ve") ||
            text.contains("o que voce esta enxergando") ||
            text.contains("o que voce ta enxergando") ||
            text.contains("o que esta enxergando") ||
            text.contains("o que ta enxergando") ||
            text.contains("descreva o que voce ve") ||
            text.contains("descreva o que esta vendo") ||
            text.contains("descreva o que ta vendo") ||
            text.contains("olhe em volta") ||
            text.contains("olha em volta") {
            return VoiceCameraCommand(
                kind: .describe,
                position: .back,
                source: "reference",
                question: "Descreva objetivamente o que aparece nesta imagem capturada pela câmera traseira do XR. Não estime distâncias métricas e não assuma movimento ou navegação."
            )
        }

        if text.contains("tira uma foto") ||
            text.contains("tira foto") ||
            text.contains("tirar uma foto") ||
            text.contains("tirar foto") ||
            text.contains("tire uma foto") ||
            text.contains("tire foto") ||
            text.contains("captura uma foto") ||
            text.contains("captura foto") ||
            text.contains("capture uma foto") ||
            text.contains("capture foto") ||
            text.contains("bate uma foto") ||
            text.contains("bate foto") ||
            text.contains("fotografa") {
            return VoiceCameraCommand(
                kind: .photo,
                position: .back,
                source: "reference",
                question: "Foto capturada pela câmera traseira do XR. Descreva rapidamente o conteúdo principal da imagem."
            )
        }

        return nil
    }

    private static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: "tars", with: " ")
            .replacingOccurrences(of: "t ars", with: " ")
            .replacingOccurrences(of: "t a r s", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
enum VoiceCameraAction {
    static func captureAndDescribe(command: VoiceCameraCommand, model: TarsHUDViewModel) async throws -> String {
        let image = try await VoiceStillCamera.capture(position: command.position)
        guard let normalized = ReferencePhoto.normalize(image) else { throw VoiceCameraError.invalidImage }
        let reply = try await model.describeImage(
            png: normalized.png,
            source: command.source,
            question: command.question
        )
        return reply.description
    }
}

final class VoiceStillCamera: NSObject, AVCapturePhotoCaptureDelegate {
    private let position: AVCaptureDevice.Position
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "tars.xr.voice.camera.capture")
    private var continuation: CheckedContinuation<UIImage, Error>?
    private var finished = false

    init(position: AVCaptureDevice.Position) {
        self.position = position
        super.init()
    }

    static func capture(position: AVCaptureDevice.Position) async throws -> UIImage {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) != nil ||
              AVCaptureDevice.default(for: .video) != nil else {
            throw VoiceCameraError.unavailable
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw VoiceCameraError.denied }
        default:
            throw VoiceCameraError.denied
        }

        let camera = VoiceStillCamera(position: position)
        return try await camera.capture()
    }

    private func capture() async throws -> UIImage {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.queue.async {
                    do {
                        try self.configure()
                        self.session.startRunning()
                        guard self.session.isRunning else { throw VoiceCameraError.captureFailed }
                        let settings = AVCapturePhotoSettings()
                        self.output.capturePhoto(with: settings, delegate: self)
                    } catch {
                        self.complete(.failure(error))
                    }
                }
            }
        }, onCancel: {
            self.complete(.failure(CancellationError()))
        })
    }

    private func configure() throws {
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        let device =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ??
            AVCaptureDevice.default(for: .video)

        guard let device else { throw VoiceCameraError.unavailable }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw VoiceCameraError.unavailable
        }

        session.addInput(input)
        session.addOutput(output)
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            complete(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            complete(.failure(VoiceCameraError.captureFailed))
            return
        }

        complete(.success(image))
    }

    private func complete(_ result: Result<UIImage, Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if self.session.isRunning { self.session.stopRunning() }

            DispatchQueue.main.async {
                guard let continuation = self.continuation else { return }
                self.continuation = nil
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}


// MARK: - External app access by voice

struct ExternalAccessCommand: Equatable {
    enum Destination: String, Equatable {
        case safari
        case deezer
        case youtube
        case gmail
        case yahooMail
        case weather
        case stocks
    }

    let destination: Destination
    let query: String?

    static func parse(_ raw: String) -> ExternalAccessCommand? {
        let text = normalize(raw)
        guard !text.isEmpty, hasAccessIntent(text) else { return nil }

        if text.contains("deezer") {
            return ExternalAccessCommand(destination: .deezer, query: query(from: text, destination: .deezer))
        }
        if text.contains("youtube") || text.contains("you tube") || text.contains("yt") {
            return ExternalAccessCommand(destination: .youtube, query: query(from: text, destination: .youtube))
        }
        if text.contains("gmail") || text.contains("google mail") {
            return ExternalAccessCommand(destination: .gmail, query: nil)
        }
        if text.contains("yahoo mail") || text.contains("yahoo email") || (text.contains("yahoo") && text.contains("mail")) {
            return ExternalAccessCommand(destination: .yahooMail, query: nil)
        }
        if text.contains("tempo") || text.contains("clima") || text.contains("weather") {
            return ExternalAccessCommand(destination: .weather, query: nil)
        }
        if text.contains("stocks") || text.contains("bolsa") || text.contains("acoes") || text.contains("acao") || text.contains("finance") {
            return ExternalAccessCommand(destination: .stocks, query: nil)
        }
        if text.contains("safari") || text.contains("google") || isGenericSearch(text) {
            return ExternalAccessCommand(destination: .safari, query: query(from: text, destination: .safari))
        }

        return nil
    }

    var spokenConfirmation: String {
        switch destination {
        case .safari:
            if let query { return "Abrindo Safari com busca por \(query)." }
            return "Abrindo Safari."
        case .deezer:
            if let query { return "Abrindo Deezer com busca por \(query)." }
            return "Abrindo Deezer."
        case .youtube:
            if let query { return "Abrindo YouTube com busca por \(query)." }
            return "Abrindo YouTube."
        case .gmail:
            return "Abrindo Gmail."
        case .yahooMail:
            return "Abrindo Yahoo Mail."
        case .weather:
            return "Abrindo Tempo."
        case .stocks:
            return "Abrindo Bolsa."
        }
    }

    var primaryURL: URL {
        switch destination {
        case .safari:
            return Self.searchURL(query) ?? URL(string: "https://www.google.com")!
        case .deezer:
            if let query { return URL(string: "https://www.deezer.com/search/\(Self.path(query))")! }
            return URL(string: "https://www.deezer.com")!
        case .youtube:
            if let query { return URL(string: "https://www.youtube.com/results?search_query=\(Self.query(query))")! }
            return URL(string: "https://www.youtube.com")!
        case .gmail:
            return URL(string: "googlegmail://")!
        case .yahooMail:
            return URL(string: "ymail://")!
        case .weather:
            return URL(string: "weather://")!
        case .stocks:
            return URL(string: "stocks://")!
        }
    }

    var fallbackURL: URL? {
        switch destination {
        case .safari:
            return query.flatMap { Self.searchURL($0) } ?? URL(string: "https://www.google.com")
        case .deezer:
            if let query { return URL(string: "https://www.deezer.com/search/\(Self.path(query))") }
            return URL(string: "https://www.deezer.com")
        case .youtube:
            if let query { return URL(string: "https://www.youtube.com/results?search_query=\(Self.query(query))") }
            return URL(string: "https://www.youtube.com")
        case .gmail:
            return URL(string: "https://mail.google.com/mail/")
        case .yahooMail:
            return URL(string: "https://mail.yahoo.com/")
        case .weather:
            return URL(string: "https://weather.com/weather/today/")
        case .stocks:
            return URL(string: "https://finance.yahoo.com/")
        }
    }

    private static func searchURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: "https://www.google.com/search?q=\(query(value))")
    }

    private static func hasAccessIntent(_ text: String) -> Bool {
        [
            "abre", "abrir", "abra", "vai no", "vai na", "vai ao", "vai a",
            "va no", "va na", "pesquisa", "pesquisar", "procura", "procurar",
            "busca", "buscar", "toca", "tocar", "executa", "executar", "coloca"
        ].contains { text.contains($0) }
    }

    private static func isGenericSearch(_ text: String) -> Bool {
        text.hasPrefix("pesquisa ") || text.hasPrefix("procura ") || text.hasPrefix("busca ") ||
        text.contains(" pesquisa ") || text.contains(" procura ") || text.contains(" busca ")
    }

    private static func query(from text: String, destination: Destination) -> String? {
        var q = " " + text + " "
        let removals = [
            "tars", "por favor", "por gentileza", "pra mim", "para mim",
            "vai no", "vai na", "vai ao", "vai a", "va no", "va na",
            "abre o", "abre a", "abre", "abrir o", "abrir a", "abrir", "abra o", "abra a", "abra",
            "pesquisa por", "pesquisa", "pesquisar", "procura por", "procura", "procurar", "busca por", "busca", "buscar",
            "toca", "tocar", "executa", "executar", "coloca", "colocar",
            "no deezer", "na deezer", "deezer", "no youtube", "na youtube", "youtube", "you tube", "yt",
            "no safari", "na safari", "safari", "no google", "google",
            "gmail", "google mail", "yahoo mail", "yahoo email", "yahoo",
            "tempo", "clima", "weather", "stocks", "bolsa", "acoes", "acao", "finance",
            "e ve se la tem", "ve se la tem", "se la tem", "la tem", "aquela musica do", "aquela musica", "musica do", "musica",
            "se tiver", "ai", "porra"
        ]
        for token in removals {
            q = q.replacingOccurrences(of: " " + token + " ", with: " ")
        }
        let collapsed = q.split(separator: " ").joined(separator: " ")
        guard collapsed.count >= 2 else { return nil }
        switch destination {
        case .gmail, .yahooMail, .weather, .stocks:
            return nil
        default:
            return collapsed
        }
    }

    private static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func query(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
    }

    private static func path(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}

@MainActor
enum ExternalAccessAction {
    static func perform(command: ExternalAccessCommand) async -> String {
        let message = command.spokenConfirmation
        let primary = command.primaryURL
        let fallback = command.fallbackURL
        Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            let opened = await open(primary)
            if !opened, let fallback { _ = await open(fallback) }
        }
        return message
    }

    private static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }
}

#if DEBUG
@MainActor
enum ExternalAccessChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        try check(ExternalAccessCommand.parse("TARS, abre o Safari")?.destination == .safari, "Safari command not detected")
        try check(ExternalAccessCommand.parse("TARS, pesquisa Palmeiras hoje")?.destination == .safari, "Generic Safari search not detected")
        try check(ExternalAccessCommand.parse("TARS, abre o Deezer")?.destination == .deezer, "Deezer command not detected")
        let deezer = ExternalAccessCommand.parse("TARS, vai no Deezer e vê se lá tem aquela música do Toots and the Maytals, 54-46. Se tiver, por favor executa, em versão ao vivo")
        try check(deezer?.destination == .deezer && (deezer?.query ?? "").contains("toots"), "Deezer search query not extracted")
        try check(ExternalAccessCommand.parse("TARS, procura no YouTube Toots and the Maytals 54-46 live")?.destination == .youtube, "YouTube search not detected")
        try check(ExternalAccessCommand.parse("TARS, abre o Gmail")?.destination == .gmail, "Gmail command not detected")
        try check(ExternalAccessCommand.parse("TARS, abre o Yahoo Mail")?.destination == .yahooMail, "Yahoo Mail command not detected")
        try check(ExternalAccessCommand.parse("TARS, abre o tempo")?.destination == .weather, "Weather command not detected")
        try check(ExternalAccessCommand.parse("TARS, abre Stocks")?.destination == .stocks, "Stocks command not detected")
        try check(ExternalAccessCommand.parse("me conta uma piada") == nil, "Ordinary conversation routed to app access")
    }
}
#endif



#if DEBUG
@MainActor
enum ReferenceCameraChecks {
    static func run() async throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        var requests = 0
        for status: AVAuthorizationStatus in [.denied, .restricted, .authorized] {
            let result = await ReferenceCameraAccess.check(available: { true }, status: { status }, request: { requests += 1; return true })
            try check(result == (status == .authorized ? .ready : .denied), "Camera authorization route")
        }
        let missing = await ReferenceCameraAccess.check(available: { false }, status: { .notDetermined }, request: { requests += 1; return true })
        try check(missing == .unavailable && requests == 0, "Unavailable/denied camera requested permission")
        for granted in [false, true] {
            let result = await ReferenceCameraAccess.check(available: { true }, status: { .notDetermined }, request: { requests += 1; return granted })
            try check(result == (granted ? .ready : .denied), "Camera permission answer ignored")
        }
        var connected = true
        let disconnected = await ReferenceCameraAccess.check(available: { connected }, status: { .notDetermined }, request: { connected = false; return true })
        try check(disconnected == .unavailable, "Camera disappeared while authorizing")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        }
        guard let photo = ReferencePhoto.normalize(large) else { throw NSError(domain: "Photo normalization failed", code: 1) }
        try check(photo.image.size == CGSize(width: 480, height: 320) && photo.image.imageOrientation == .up, "Photo resolution/orientation")
        try check(ReferencePhoto.normalize(UIImage()) == nil, "Empty photo accepted")
        try photo.png.write(to: URL.documentsDirectory.appendingPathComponent("normalized-camera-check.png"), options: .atomic)
        var callbacks = 0
        let coordinator = ReferenceCamera.Coordinator { image in callbacks += 1; assert(image != nil) }
        let picker = UIImagePickerController()
        coordinator.imagePickerController(picker, didFinishPickingMediaWithInfo: [.originalImage: large])
        coordinator.imagePickerControllerDidCancel(picker)
        try check(callbacks == 1, "Camera emitted duplicate result")
        var cancelled = false
        let cancel = ReferenceCamera.Coordinator { cancelled = $0 == nil }
        cancel.imagePickerControllerDidCancel(picker)
        try check(cancelled, "Camera cancel did not return empty result")
    }
}
@MainActor
enum VoiceCameraCommandChecks {
    static func run() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }

        try check(VoiceCameraCommand.parse("TARS, o que você está vendo?")?.kind == .describe, "Voice camera describe command not detected")
        try check(VoiceCameraCommand.parse("TARS, o que você tá vendo?")?.kind == .describe, "Voice camera colloquial ta vendo not detected")
        try check(VoiceCameraCommand.parse("TARS, abre a câmera aí")?.kind == .describe, "Voice camera open camera command not detected")
        try check(VoiceCameraCommand.parse("TARS, procure a Mel")?.kind == .findMel, "Voice camera Mel command not detected")
        try check(VoiceCameraCommand.parse("TARS, cadê a Mel?")?.kind == .findMel, "Voice camera colloquial Mel command not detected")
        try check(VoiceCameraCommand.parse("TARS, tire uma foto")?.kind == .photo, "Voice camera photo command not detected")
        try check(VoiceCameraCommand.parse("TARS, tira foto")?.kind == .photo, "Voice camera short photo command not detected")
        try check(VoiceCameraCommand.parse("TARS, tira uma selfie")?.position == .front, "Voice camera selfie must use front camera")
        try check(VoiceCameraCommand.parse("me conta uma piada") == nil, "Non-camera command routed to camera")
        try ExternalAccessChecks.run()
    }
}



#endif
