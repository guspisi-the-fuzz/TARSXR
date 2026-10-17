import SwiftUI
import Combine
import WebKit
import AVFoundation

@MainActor
final class YouTubeMusicPlayer: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var track: YouTubeTrack?
    @Published private(set) var status = ""
    @Published private(set) var isPlaying = false
    private var storedWebView: WKWebView?
    var hasCreatedWebView: Bool { storedWebView != nil }
    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let view=makeWebView(); storedWebView=view; return view
    }
    var visible = false
    var onMediaSessionConfirmed: (() -> Void)?
    private var generation = UUID()
    private var playbackState = -1
    private var errorMessage: String?
    private var titleRequestedAt: Date?
    private var pendingCommand: MusicCommand?
    private var pageGeneration = UUID()

    override init() {
        super.init()
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Align WebKit's audio-session intent with the native microphone session.
        // Without this, activating capture can interrupt the embedded video.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "if(navigator.audioSession){navigator.audioSession.type='play-and-record';}",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "music")
        let view=WKWebView(frame:.zero,configuration:configuration)
        view.isOpaque=false; view.backgroundColor = .black
        return view
    }

    func command(for text: String) -> MusicCommand? {
        if let command = MusicCommand.parse(text, mediaActive: track != nil) { return command }
        if let requested = titleRequestedAt, Date().timeIntervalSince(requested) < 60,
           !text.contains("?"), text.count <= 200,
           !["jogo", "joga", "camera", "câmera", "abre", "pare", "dorme"].contains(where: { text.lowercased().contains($0) }) {
            return .play(text)
        }
        return nil
    }

    func handle(_ command: MusicCommand) async -> String {
        do { return try await execute(command).speech }
        catch { return "Interrompi a espera do pedido de música." }
    }

    func cancelPendingCommand() {
        titleRequestedAt = nil
        guard let command = pendingCommand else { return }
        generation = UUID(); pendingCommand = nil
        if case .play = command, !isPlaying {
            pageGeneration = UUID(); storedWebView?.stopLoading()
            storedWebView?.loadHTMLString("", baseURL: nil); track = nil
            status = "Carregamento interrompido"; playbackState = -1
        }
    }

    func execute(_ command: MusicCommand) async throws -> LocalActionResult {
        try Task.checkCancellation()
        let id = UUID(); generation = id; pendingCommand = command
        defer { if generation == id { pendingCommand = nil } }
        switch command {
        case .play(let query):
            if query.isEmpty { titleRequestedAt = Date(); return LocalActionResult(.needsInput, "Qual música e artista você quer ouvir?") }
            titleRequestedAt = nil
            pageGeneration = UUID()
            status = "Buscando no YouTube…"; errorMessage = nil; isPlaying = false; playbackState = -1
            storedWebView?.loadHTMLString("", baseURL: nil); track = nil
            do {
                let found = try await YouTubeSearch.find(query)
                try Task.checkCancellation()
                guard generation == id else { throw CancellationError() }
                track = found; status = "Carregando \(found.title)…"
                // Wait for SwiftUI to mount the visible player before enabling autoplay.
                for _ in 0..<20 {
                    if visible { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard generation == id, visible else { return LocalActionResult(.failed, "Não consegui exibir o player de música.") }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
                try session.setActive(true)
                let origin = "https://" + (Bundle.main.bundleIdentifier ?? "com.pisi.tarsxr")
                webView.loadHTMLString(Self.page(videoID: found.id, origin: origin, token: pageGeneration.uuidString), baseURL: URL(string: origin))
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == id else { throw CancellationError() }
                    if isPlaying { return LocalActionResult(.succeeded, "", observation: "O player confirmou a reprodução de " + found.title + ". Isso não verifica o som físico no alto-falante.", confirmation: "youtube.state.playing") } // Keep song playback silent.
                    if let errorMessage { return LocalActionResult(.failed, errorMessage) }
                }
                status = "O YouTube não confirmou a reprodução. Use Play no vídeo."
                return LocalActionResult(.unconfirmed, "O vídeo foi carregado, mas o YouTube não confirmou a reprodução. Toque em Play no vídeo.")
            } catch {
                if Task.isCancelled || error is CancellationError { if generation == id { cancelPendingCommand() }; throw CancellationError() }
                guard generation == id else { throw CancellationError() }
                status = "Não consegui carregar a música."
                return LocalActionResult(.failed, "Não consegui carregar essa música no YouTube. Tente dizer o nome e o artista.")
            }
        case .pause:
            guard track != nil else { return LocalActionResult(.unavailable, "Não há música aberta.") }
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.pauseVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == id else { throw CancellationError() }
                    if playbackState == 2 { return LocalActionResult(.succeeded, "", observation: "O player confirmou a pausa.", confirmation: "youtube.state.paused") }
                }
                return LocalActionResult(.unconfirmed, "O YouTube ainda não confirmou a pausa.")
            } catch {
                if Task.isCancelled || error is CancellationError || generation != id { if generation == id { cancelPendingCommand() }; throw CancellationError() }
                return LocalActionResult(.failed, "Não consegui pausar o vídeo agora.") }
        case .resume:
            guard track != nil else { return LocalActionResult(.needsInput, "Diga o nome da música que você quer ouvir.") }
            errorMessage = nil
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.playVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == id else { throw CancellationError() }
                    if isPlaying { return LocalActionResult(.succeeded, "", observation: "O player confirmou a reprodução.", confirmation: "youtube.state.playing") }
                    if let errorMessage { return LocalActionResult(.failed, errorMessage) }
                }
                return LocalActionResult(.unconfirmed, "O YouTube não confirmou a retomada. Toque em Play no vídeo.")
            } catch {
                if Task.isCancelled || error is CancellationError || generation != id { if generation == id { cancelPendingCommand() }; throw CancellationError() }
                return LocalActionResult(.failed, "Não consegui retomar o vídeo agora.") }
        case .restart:
            guard track != nil else { return LocalActionResult(.needsInput, "Diga o nome da música que você quer ouvir.") }
            errorMessage = nil
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.seekTo(0,true);player.playVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == id else { throw CancellationError() }
                    let restarted = try await webView.evaluateJavaScript("player.getPlayerState()===1 && player.getCurrentTime()<3")
                    try Task.checkCancellation()
                    guard generation == id else { throw CancellationError() }
                    if restarted as? Bool == true { return LocalActionResult(.succeeded, "", observation: "O player confirmou reprodução no início da faixa.", confirmation: "youtube.playing.position.below3s") }
                    if let errorMessage { return LocalActionResult(.failed, errorMessage) }
                }
                return LocalActionResult(.unconfirmed, "O YouTube ainda não confirmou o reinício da música.")
            } catch {
                if Task.isCancelled || error is CancellationError || generation != id { if generation == id { cancelPendingCommand() }; throw CancellationError() }
                return LocalActionResult(.failed, "Não consegui reiniciar o vídeo agora.") }
        case .stop:
            pageGeneration = UUID(); titleRequestedAt = nil; playbackState = -1; errorMessage = nil
            storedWebView?.loadHTMLString("", baseURL: nil); track = nil; isPlaying = false; status = ""
            return LocalActionResult(.succeeded, "Música encerrada.", confirmation: "local.player.cleared")
        }
    }

    #if DEBUG
    /// Real command dispatch/player lifecycle with a local fixture, no YouTube request or microphone.
    static func runExitChecks() async -> String {
        let player = YouTubeMusicPlayer()
        player.pauseForBackground(); player.cancelPendingCommand()
        guard !player.hasCreatedWebView else { return "FAIL: idle player created WebKit" }
        let phrases = ["Fecho o YouTube", "Para o YouTube", "Stop the YouTube", "TARS, fecha o YouTube", "Volta pra conversa"]
        for phrase in phrases {
            player.track = YouTubeTrack(id:"abcdefghijk",title:"Local fixture")
            player.isPlaying = true; player.playbackState = 1
            player.titleRequestedAt = Date(); player.errorMessage = "old error"
            let previous = player.generation
            guard let command = player.command(for:phrase), command == .stop else { return "FAIL: exit not routed" }
            _ = await player.handle(command)
            guard player.track == nil, !player.isPlaying, player.status.isEmpty,
                  player.titleRequestedAt == nil, player.playbackState == -1,
                  player.errorMessage == nil, player.generation != previous else { return "FAIL: player retained state" }
            guard player.command(for:"Quem é a gata?") == nil,
                  MusicSpeechPolicy.accepts("Além de mim, com quem ela mora?",musicActive:player.isPlaying) else { return "FAIL: conversation blocked after exit" }
        }
        player.track = YouTubeTrack(id:"abcdefghijk",title:"Paused fixture")
        player.isPlaying = false
        guard MusicSpeechPolicy.accepts("Quem é a gata?",musicActive:player.isPlaying) else { return "FAIL: paused player blocks conversation" }
        _ = await player.handle(.stop)
        do {
            let absent = try await player.execute(.pause)
            guard absent.status == .unavailable else { return "FAIL: absent player reported success" }
            let prompt = try await player.execute(.play(""))
            guard prompt.status == .needsInput else { return "FAIL: title prompt reported success" }
            player.track = YouTubeTrack(id: "abcdefghijk", title: "Pending fixture")
            player.isPlaying = false; player.pendingCommand = .play("fixture")
            let oldPage = player.pageGeneration
            player.cancelPendingCommand()
            guard player.track == nil, player.pageGeneration != oldPage else { return "FAIL: pending playback survived cancellation" }
            player.track = YouTubeTrack(id: "abcdefghijk", title: "Playing fixture")
            player.isPlaying = true; player.pendingCommand = .play("fixture")
            player.cancelPendingCommand()
            guard player.track != nil, player.isPlaying else { return "FAIL: cancelling wait stopped established playback" }
            let cleared = try await player.execute(.stop)
            guard cleared.status == .succeeded, !cleared.confirmation.isEmpty, player.track == nil else { return "FAIL: stop lacks confirmed receipt" }
        } catch { return "FAIL: music receipt/cancellation fixture" }
        guard !player.hasCreatedWebView else { return "FAIL: no-playback commands created WebKit" }
        return "PASS: lazy WebKit remains absent for idle/background/empty-title/stop/cancellation; actual music receipts, needs-input/unavailable distinction, pending cancellation without undoing playback, and 5 natural exits through actual player; track cleared (window condition false), generation cancelled, title prompt cleared, paused/exited conversation enabled; no network/audio"
    }
    #endif

    func pauseForBackground() {
        storedWebView?.evaluateJavaScript("if(window.player) player.pauseVideo()", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], let kind = value["kind"] as? String,
              MusicCallbackPolicy.accepts(value, videoID: track?.id, token: pageGeneration.uuidString) else { return }
        #if DEBUG
        var diagnostic = value
        let session = AVAudioSession.sharedInstance()
        diagnostic["systemVolume"] = session.outputVolume
        diagnostic["route"] = session.currentRoute.outputs.map { $0.portType.rawValue }
        diagnostic["category"] = session.category.rawValue
        diagnostic["mode"] = session.mode.rawValue
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("music-playback-diagnostic.json"), options: .atomic)
        }
        #endif
        if kind == "state", let state = value["value"] as? Int {
            playbackState = state
            isPlaying = state == 1
            if state == 1 { onMediaSessionConfirmed?(); status = "Tocando: \(track?.title ?? "")" }
            else if state == 2 { onMediaSessionConfirmed?(); status = "Pausado" }
            else if state == 0 { status = "Reprodução concluída" }
        } else if kind == "time", playbackState == 1 || playbackState == 2 {
            onMediaSessionConfirmed?()
        } else if kind == "error" || kind == "blocked" {
            isPlaying = false
            errorMessage = "O YouTube bloqueou a reprodução deste vídeo no TARS. Tente outra versão da música."
            status = errorMessage!
        }
    }

    static func page(videoID: String, origin: String, token: String) -> String {
        // IDs and origin are internal validated values; no user query is executed as script.
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#player{margin:0;width:100%;height:100%;background:black}</style></head><body><div id="player"></div>
        <script>var player;function report(k,v){webkit.messageHandlers.music.postMessage({kind:k,value:v,id:'\(videoID)',token:'\(token)',rate:player?player.getPlaybackRate():null,volume:player?player.getVolume():null})}
        function onYouTubeIframeAPIReady(){player=new YT.Player('player',{videoId:'\(videoID)',playerVars:{playsinline:1,autoplay:1,origin:'\(origin)'},events:{onReady:function(e){e.target.setPlaybackRate(1);e.target.setVolume(100);\(ProcessInfo.processInfo.environment["TARS_YOUTUBE_MUTED_PROBE"] == "1" ? "e.target.mute();" : "")e.target.playVideo();setInterval(function(){if([1,2].includes(player.getPlayerState()))report('time',player.getCurrentTime())},2000)},onStateChange:function(e){report('state',e.data)},onError:function(e){report('error',e.data)},onAutoplayBlocked:function(){report('blocked',0)}}})}</script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
    }
}

struct YouTubeMusicView: UIViewRepresentable {
    @ObservedObject var player: YouTubeMusicPlayer
    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
