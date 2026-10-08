import SwiftUI
import Combine
import WebKit
import AVFoundation

@MainActor
final class YouTubeMusicPlayer: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published private(set) var track: YouTubeTrack?
    @Published private(set) var status = ""
    @Published private(set) var isPlaying = false
    private(set) var webView: WKWebView!
    var visible = false
    var onMediaSessionConfirmed: (() -> Void)?
    private var generation = UUID()
    private var playbackState = -1
    private var errorMessage: String?
    private var titleRequestedAt: Date?

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        // Align WebKit's audio-session intent with the native microphone session.
        // Without this, activating capture can interrupt the embedded video.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "if(navigator.audioSession){navigator.audioSession.type='play-and-record';}",
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "music")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
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
        switch command {
        case .play(let query):
            if query.isEmpty { titleRequestedAt = Date(); return "Qual música e artista você quer ouvir?" }
            titleRequestedAt = nil
            let id = UUID(); generation = id
            status = "Buscando no YouTube…"; errorMessage = nil; isPlaying = false; playbackState = -1
            webView.loadHTMLString("", baseURL: nil); track = nil
            do {
                let found = try await YouTubeSearch.find(query)
                try Task.checkCancellation()
                guard generation == id else { return "" }
                track = found; status = "Carregando \(found.title)…"
                // Wait for SwiftUI to mount the visible player before enabling autoplay.
                for _ in 0..<20 {
                    if visible { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard generation == id, visible else { return "Não consegui exibir o player de música." }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
                try session.setActive(true)
                let origin = "https://" + (Bundle.main.bundleIdentifier ?? "com.pisi.tarsxr")
                webView.loadHTMLString(Self.page(videoID: found.id, origin: origin), baseURL: URL(string: origin))
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(200))
                    guard generation == id else { return "" }
                    if isPlaying { return "" } // Do not talk over the beginning of the song.
                    if let errorMessage { return errorMessage }
                }
                status = "O YouTube não confirmou a reprodução. Use Play no vídeo."
                return "O vídeo foi carregado, mas o YouTube não iniciou a reprodução. Toque em Play no vídeo."
            } catch {
                guard generation == id else { return "" }
                status = "Não consegui carregar a música."
                return "Não consegui carregar essa música no YouTube. Tente dizer o nome e o artista."
            }
        case .pause:
            guard track != nil else { return "Não há música aberta." }
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.pauseVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    if playbackState == 2 { return "" } // The silence and visible status confirm pause without changing audio sessions.
                }
                return "O YouTube ainda não confirmou a pausa."
            } catch { return "Não consegui pausar o vídeo agora." }
        case .resume:
            guard track != nil else { return "Diga o nome da música que você quer ouvir." }
            errorMessage = nil
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.playVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    if isPlaying { return "" }
                    if let errorMessage { return errorMessage }
                }
                return "O YouTube não confirmou a retomada. Toque em Play no vídeo."
            } catch { return "Não consegui retomar o vídeo agora." }
        case .restart:
            guard track != nil else { return "Diga o nome da música que você quer ouvir." }
            errorMessage = nil
            do {
                _ = try await webView.evaluateJavaScript("(()=>{player.seekTo(0,true);player.playVideo();return true})()")
                for _ in 0..<25 {
                    try await Task.sleep(for: .milliseconds(200))
                    let restarted = try await webView.evaluateJavaScript("player.getPlayerState()===1 && player.getCurrentTime()<3")
                    if restarted as? Bool == true { return "" }
                    if let errorMessage { return errorMessage }
                }
                return "O YouTube ainda não confirmou o reinício da música."
            } catch { return "Não consegui reiniciar o vídeo agora." }
        case .stop:
            generation = UUID(); titleRequestedAt = nil
            webView.loadHTMLString("", baseURL: nil); track = nil; isPlaying = false; status = ""
            return "Música encerrada."
        }
    }

    func pauseForBackground() {
        webView.evaluateJavaScript("if(window.player) player.pauseVideo()", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], let kind = value["kind"] as? String,
              value["id"] as? String == track?.id else { return }
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

    static func page(videoID: String, origin: String) -> String {
        // IDs and origin are internal validated values; no user query is executed as script.
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#player{margin:0;width:100%;height:100%;background:black}</style></head><body><div id="player"></div>
        <script>var player;function report(k,v){webkit.messageHandlers.music.postMessage({kind:k,value:v,id:'\(videoID)',rate:player?player.getPlaybackRate():null,volume:player?player.getVolume():null})}
        function onYouTubeIframeAPIReady(){player=new YT.Player('player',{videoId:'\(videoID)',playerVars:{playsinline:1,autoplay:1,origin:'\(origin)'},events:{onReady:function(e){e.target.setPlaybackRate(1);e.target.setVolume(100);\(ProcessInfo.processInfo.environment["TARS_YOUTUBE_MUTED_PROBE"] == "1" ? "e.target.mute();" : "")e.target.playVideo();setInterval(function(){if([1,2].includes(player.getPlayerState()))report('time',player.getCurrentTime())},2000)},onStateChange:function(e){report('state',e.data)},onError:function(e){report('error',e.data)},onAutoplayBlocked:function(){report('blocked',0)}}})}</script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
    }
}

struct YouTubeMusicView: UIViewRepresentable {
    @ObservedObject var player: YouTubeMusicPlayer
    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
