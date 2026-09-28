import SwiftUI
import PhotosUI
import ImageIO

struct TarsHUDView: View {
    @StateObject var model: TarsHUDViewModel
    @State private var showsTests = false
    @State private var showsVision = false
    // Manual controls are opt-in diagnostics, never the normal interaction flow.
    private var manualDiagnostics: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["TARS_MANUAL_DIAGNOSTICS"] == "1"
        #else
        return false
        #endif
    }
    private var simulatedVoiceChecks: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["TARS_VOICE_CHECKS"] == "1"
            || ProcessInfo.processInfo.environment["TARS_LOCAL_VOICE_PROBE"] == "1"
        #else
        return false
        #endif
    }
    @StateObject private var audio = XRAudioController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                CognitiveDisplay(state: audio.state, level: audio.level)
                    .frame(maxHeight: .infinity)
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["TARS_VISION_TEST"] == "1" {
                    Button("Teste de visão") { showsVision = true }
                        .buttonStyle(.bordered).tint(.cyan)
                }
                if manualDiagnostics {
                Button { showsTests = true } label: {
                    Label("Painel de Testes", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(.cyan).padding(.horizontal, 16)
                }
                #endif
                if manualDiagnostics {
                    AudioControls(audio: audio)
                } else {
                    VStack(spacing: 4) {
                        Text(audio.message)
                        Text(audio.voiceSource).font(.caption2)
                        if !audio.lastHeard.isEmpty {
                            Text("Ouvi: \(audio.lastHeard)").foregroundStyle(.cyan).lineLimit(3)
                        }
                        if !audio.voiceProgress.isEmpty {
                            Text(audio.voiceProgress).lineLimit(3)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                Rectangle().frame(height: 1).foregroundStyle(.green)
                EngineeringPanel(model: model, audioStatus: audio.status)
                    .frame(maxHeight: .infinity)
            }
            .foregroundStyle(.green)
            .fontDesign(.monospaced)
        }
        #if DEBUG && targetEnvironment(simulator)
        .sheet(isPresented: $showsVision) { VisionTestPanel(model: model, audio: audio) }
        .sheet(isPresented: $showsTests) {
            SimulatorTestPanel(model: model)
        }
        #endif
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["TARS_VISION_CHECKS"] == "1" {
                let data = VisionTestPanel.fixture().pngData()
                try? data?.write(to: URL.documentsDirectory.appendingPathComponent("vision-fixture.png"), options: .atomic)
                return
            }
            if simulatedVoiceChecks {
                let localProbe = ProcessInfo.processInfo.environment["TARS_LOCAL_VOICE_PROBE"] == "1"
                let result = localProbe
                    ? await XRAudioController.runLocalRecognitionProbe()
                    : await XRAudioController.runSimulatedCycleChecks()
                let file = URL.documentsDirectory.appendingPathComponent(localProbe ? "local-voice-probe.txt" : "voice-cycle-checks.txt")
                try? result.write(to: file, atomically: true, encoding: .utf8)
                print(result)
                return
            }
            #endif
            audio.streamConversation = { text, receive, receiveText in try await model.streamConversation(text: text, receive: receive, receiveText: receiveText) }
            audio.streamSpeech = { text, receive in try await model.streamSpeech(text: text, receive: receive) }
            audio.synthesize = { text in try await model.synthesize(text: text) }
            audio.transcribe = { data in try await model.transcribe(data: data) }
            audio.respond = { text, language in try await model.converse(text: text, language: language) }
            await model.run()
        }
        .task(id: scenePhase) {
            guard !showsVision, !manualDiagnostics, !simulatedVoiceChecks, ProcessInfo.processInfo.environment["TARS_PAUSE_VOICE"] != "1", ProcessInfo.processInfo.environment["TARS_VISION_CHECKS"] != "1" else { return }
            if scenePhase == .active {
                await audio.enableHandsFree()
            } else if scenePhase == .background {
                audio.suspendHandsFree()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if manualDiagnostics && phase == .background { audio.cancel(message: "Áudio pausado fora do app.") }
        }
        .onDisappear { audio.suspendHandsFree() }
    }
}

struct CognitiveDisplay: View {
    let state: String
    var level: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var energy: Double {
        switch state.uppercased() {
        case "LISTENING": return 1.3
        case "THINKING": return 1.8
        case "SPEAKING": return 1.5
        default: return 0.65
        }
    }
    var body: some View {
        GeometryReader { g in
            ZStack {
                RadialGradient(colors: [Color.purple.opacity(0.16), .black],
                               center: .center, startRadius: 0, endRadius: g.size.width * 0.6)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: reduceMotion || scenePhase != .active)) { timeline in
                    let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        drawAtom(context: &context, size: size, time: t)
                    }
                }
                // Keep microphone transforms outside TimelineView/Canvas so level
                // updates always invalidate the visible transform, not only its drawing closure.
                .scaleEffect(reduceMotion ? 1 : 1 + level * 0.38)
                .rotationEffect(.degrees(reduceMotion ? 0 : level * 18))
                .animation(.easeOut(duration: 0.10), value: level)
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("T A R S").font(.system(size: 19, weight: .medium, design: .monospaced))
                        .tracking(9).foregroundStyle(.white.opacity(0.92))
                    Text("COGNITIVE INTERFACE").font(.system(size: 8, design: .monospaced))
                        .tracking(3).foregroundStyle(.cyan.opacity(0.65))
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(.cyan).frame(width: 4, height: 4)
                        Text(state.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(3).foregroundStyle(.white.opacity(0.85))
                    }
                }.padding(.vertical, 22)
            }.frame(width: g.size.width, height: g.size.height)
                .clipped()
        }
    }

    // Microphone RMS drives expansion; synthesized speech uses its actual lifecycle state.
    private func drawAtom(context: inout GraphicsContext, size: CGSize, time: Double) {
        let clock = time.truncatingRemainder(dividingBy: 3600)
        // Smooth deterministic waves avoid random frame-to-frame flicker.
        // Speaking motion is illustrative; listening motion uses microphone RMS.
        let activity = reduceMotion ? 0 : (state == "SPEAKING" ? 0.45 : min(1, level * 1.5))
        let center = CGPoint(x: size.width / 2 + sin(clock * 3.1) * activity * 9,
                             y: size.height / 2 + cos(clock * 2.7) * activity * 9)
        let radius = max(12, min(size.width * 0.26, (size.height - 105) * 0.32))
        let breath = 1 + 0.035 * sin(clock * energy * 1.7) + activity * 0.08 * sin(clock * 7)
        let r = radius * breath
        let halo = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        context.fill(Path(ellipseIn: halo), with: .radialGradient(
            Gradient(colors: [.purple.opacity(0.2), .blue.opacity(0.06), .clear]),
            center: center, startRadius: 0, endRadius: r))
        for orbit in 0..<3 {
            let rotation = Double(orbit) * .pi / 3 + 0.15 * sin(clock * 0.15)
                + activity * sin(clock * (1.8 + Double(orbit) * 0.4) + Double(orbit)) * 1.1
            func point(_ angle: Double) -> CGPoint {
                let wave = sin(angle * 5 + clock * 5 + Double(orbit) * 2)
                    + 0.45 * sin(angle * 9 - clock * 3)
                let distortedRadius = r * (1 + activity * 0.20 * wave)
                let x = cos(angle) * distortedRadius
                let flattening = 0.36 + activity * 0.22 * sin(clock * 2 + Double(orbit))
                let y = sin(angle) * distortedRadius * flattening
                return CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                               y: center.y + x * sin(rotation) + y * cos(rotation))
            }
            for segment in 0..<120 {
                let a = Double(segment) / 120 * .pi * 2
                let b = Double(segment + 1) / 120 * .pi * 2
                let hue = (Double(segment) / 240 + Double(orbit) * 0.15 + clock * 0.025)
                    .truncatingRemainder(dividingBy: 1)
                let color = Color(hue: hue, saturation: 0.8, brightness: 1)
                var path = Path(); path.move(to: point(a)); path.addLine(to: point(b))
                context.stroke(path, with: .color(color.opacity(0.08)), lineWidth: 9)
                context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 3)
                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
            }
            let angle = clock * energy * 0.8 + Double(orbit) * 2.1
            let electron = point(angle)
            let glow = CGRect(x: electron.x - 10, y: electron.y - 10, width: 20, height: 20)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(colors: [.cyan.opacity(0.9), .purple.opacity(0.3), .clear]),
                center: electron, startRadius: 0, endRadius: 10))
            context.fill(Path(ellipseIn: CGRect(x: electron.x - 2, y: electron.y - 2,
                                               width: 4, height: 4)), with: .color(.white))
        }
        // Particle corona swells and flows with the same microphone envelope.
        for particle in 0..<36 {
            let phase = Double(particle) * .pi * 2 / 36
            let theta = phase + clock * 0.35
            let distance = r * (0.65 + activity * 0.35 * sin(phase * 3 + clock * 2.5))
            let p = CGPoint(x: center.x + cos(theta) * distance,
                            y: center.y + sin(theta) * distance)
            let dot = 1 + activity * 2
            context.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot,
                                               width: dot * 2, height: dot * 2)),
                         with: .color(Color(hue: Double(particle) / 36, saturation: 0.7,
                                            brightness: 1).opacity(0.15 + activity * 0.65)))
        }
        let core = 17.0 * breath * (1 + activity * 0.8)
        context.fill(Path(ellipseIn: CGRect(x: center.x - core * 2, y: center.y - core * 2,
                                           width: core * 4, height: core * 4)),
                     with: .radialGradient(Gradient(colors: [.cyan.opacity(0.7), .pink.opacity(0.3), .clear]),
                                           center: center, startRadius: 0, endRadius: core * 2))
        context.fill(Path(ellipseIn: CGRect(x: center.x - core / 2, y: center.y - core / 2,
                                           width: core, height: core)),
                     with: .radialGradient(Gradient(colors: [.white, .cyan, .purple]),
                                           center: center, startRadius: 0, endRadius: core))
    }
}

struct EngineeringPanel: View {
    @ObservedObject var model: TarsHUDViewModel
    var audioStatus: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("SYSTEM STATUS").bold(); Spacer(); Text(model.connected ? "LINK" : "OFFLINE") }
                Divider().overlay(.green.opacity(0.5))
                ForEach(model.systemRows, id: \.0) { row in
                    HStack { Text(row.0); Spacer(); Text(row.0 == "AUDIO" ? audioStatus : row.1).bold() }
                }
                Divider().overlay(.green.opacity(0.5))
                HStack(alignment: .top) {
                    metricColumn("SENSORS", rows: model.sensorRows)
                    metricColumn("COMPUTE", rows: model.computeRows)
                }
                Text("> \(model.logLine)").font(.caption).padding(.top, 4)
                if model.needsConnectionHelp {
                    Button("Tentar conexão novamente") { Task { await model.retryConnection() } }
                        .buttonStyle(.bordered)
                }

            }.padding(14)
        }
    }
    private func metricColumn(_ title: String, rows: [(String,String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).bold()
            ForEach(rows, id: \.0) { r in HStack { Text(r.0); Spacer(); Text(r.1) } }
        }.frame(maxWidth: .infinity)
    }
}


private struct AudioControls: View {
    @ObservedObject var audio: XRAudioController
    var body: some View {
        VStack(spacing: 8) {
            Toggle("Conversar com IA", isOn: $audio.useAI)
                .font(.caption).tint(.cyan).disabled(audio.state != "IDLE")
            Text(audio.useAI ? "Idioma automático · voz multilíngue" : "Teste local em português · multilíngue aguarda API")
                .font(.caption2).foregroundStyle(.gray)
            if audio.state == "LISTENING" {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill").foregroundStyle(.cyan)
                    ForEach(0..<16, id: \.self) { index in
                        Capsule().fill(Double(index) / 16 < audio.level ? Color.cyan : Color.cyan.opacity(0.12))
                            .frame(height: 7)
                    }
                }.accessibilityLabel("Nível do microfone")
                Text(audio.inputName).font(.caption2).foregroundStyle(.gray).lineLimit(1)
            }
            if !audio.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OUVI ISTO:").font(.caption2).foregroundStyle(.cyan)
                    ScrollView {
                        Text(audio.transcript).foregroundStyle(.white).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 65)
                }
            }
            Text(audio.message).foregroundStyle(.cyan.opacity(0.8))
                .font(.caption2).lineLimit(3).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                if audio.state == "IDLE" {
                    Button { Task { await audio.start() } } label: {
                        Label("Falar", systemImage: "mic.fill")
                    }
                    Button("Testar voz") { audio.testVoice() }
                } else {
                    if audio.state == "LISTENING" {
                        Button("Concluir") { audio.finish() }
                    }
                    Button("Cancelar") { audio.cancel() }
                }
            }.buttonStyle(.bordered).tint(.cyan).font(.caption)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct SimulatorTestPanel: View {
    @ObservedObject var model: TarsHUDViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRecovery = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(model.virtualSimulator ? "MODO SIMULADO · ESP32 VIRTUAL" : "SIMULADOR NÃO CONFIRMADO",
                          systemImage: "desktopcomputer")
                        .font(.caption.bold()).foregroundStyle(.cyan)
                    VStack(spacing: 12) {
                        status("Conexão", model.connected ? "Core conectado" : "Sem conexão")
                        status("Movimento", model.motionStatus)
                        status("Segurança", model.safetyStatus)
                    }
                    Text(model.connectionMessage).font(.callout).foregroundStyle(.cyan)
                    if model.needsConnectionHelp {
                        Button("Tentar conexão novamente") { Task { await model.retryConnection() } }
                            .buttonStyle(.bordered)
                    }
                    Text(model.safetyGuidance).font(.callout).foregroundStyle(.secondary)
                    Button { Task { await model.simulatorCommand("ESTOP") } } label: {
                        Label("E-STOP · Parada de emergência", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!model.connected || !model.virtualSimulator)
                    HStack {
                        Button("Mover 250 ms") { Task { await model.simulatorCommand("MOVE") } }
                            .disabled(!model.canMove || model.commandPending)
                        Button("Parar") { Task { await model.simulatorCommand("STOP") } }
                            .disabled(!model.connected || !model.virtualSimulator)
                    }.buttonStyle(.bordered).controlSize(.large)
                    Button("Confirmar recuperação") { confirmsRecovery = true }
                        .buttonStyle(.bordered)
                        .disabled(!model.connected || !model.virtualSimulator || model.safetyStatus != "Bloqueado" || model.commandPending)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ÚLTIMO RESULTADO").font(.caption.bold()).foregroundStyle(.cyan)
                        Text(model.commandStatus.isEmpty ? "Nenhum comando enviado nesta sessão." : model.commandStatus)
                            .textSelection(.enabled)
                    }
                    Text("Estado atualizado a cada consulta ao Core (cerca de 0,5 s). Um movimento de 250 ms pode terminar entre consultas. A aceitação do comando não confirma deslocamento físico.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .background(Color.black).foregroundStyle(.white)
            .navigationTitle("Painel de Testes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
            .confirmationDialog("Liberar o bloqueio de segurança?", isPresented: $confirmsRecovery, titleVisibility: .visible) {
                Button("Confirmar recuperação") { Task { await model.simulatorCommand("RECOVER") } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("O Core verificará as condições de segurança. Recuperar não inicia movimento; será necessário um novo comando.")
            }
        }.preferredColorScheme(.dark)
    }

    private func status(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).bold() }
    }
}
#endif


#if DEBUG && targetEnvironment(simulator)
/// Explicit, one-image reference test. No camera or background upload.
private struct VisionTestPanel: View {
    @ObservedObject var model: TarsHUDViewModel
    @ObservedObject var audio: XRAudioController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var png: Data?
    @State private var source = "simulation"
    @State private var question = "Descreva o que aparece nesta imagem em português."
    @State private var result = "Escolha uma imagem ou use a cena de teste."
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var visualConversation: VisualConversation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Imagem de referência · câmera desligada").font(.headline)
                    if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230) }
                    Button("Usar cena de teste") { selected = nil; setImage(Self.fixture(), source: "simulation") }
                        .disabled(busy)
                    PhotosPicker("Escolher uma foto", selection: $selected, matching: .images).disabled(busy)
                    TextField("Pergunta sobre a imagem", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder).disabled(busy)
                    Text("Ao tocar em Descrever, esta imagem e sua pergunta serão enviadas à OpenAI. A resposta será falada com a voz do TARS. Análise e voz consomem API; o microfone continua pausado.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(busy ? "Analisando…" : "Descrever imagem") { analyze() }
                        .buttonStyle(.borderedProminent).disabled(png == nil || busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 500)
                    if visualConversation == nil {
                        Button("Conversar sobre esta imagem") { startVisualConversation() }
                            .disabled(png == nil || busy || ProcessInfo.processInfo.environment["TARS_ONLINE_WAKE"] != "1")
                        Text("Teste de até 3 minutos ou 6 perguntas sobre esta mesma imagem. A escuta online envia trechos de fala à OpenAI, inclusive antes de TARS. Imagem, transcrição, análise e voz consomem API.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Parar conversa visual") { stop() }
                        Text("Diga TARS e pergunte sobre a imagem; depois pode continuar sem repetir o nome por 30 segundos.")
                        Text(audio.message).textSelection(.enabled)
                    }
                    Text(result).textSelection(.enabled)
                    Text(audio.voiceProgress).font(.caption).foregroundStyle(.secondary)
                    Text("A descrição se refere apenas à imagem escolhida. Não mede distâncias e não libera movimentos.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Teste de visão")
            .toolbar { Button("Fechar") { dismiss() } }
            .task(id: selected) {
                guard let selected else { return }
                do {
                    guard let data = try await selected.loadTransferable(type: Data.self), data.count <= 20_000_000,
                          let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary) else {
                        result = "Não consegui abrir essa imagem."; return
                    }
                    try Task.checkCancellation()
                    setImage(UIImage(cgImage: thumb), source: "reference")
                } catch { if !Task.isCancelled { result = "Não consegui carregar a foto." } }
            }
            .onAppear { audio.suspendHandsFree() }
            .onDisappear { stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        }
    }
    private func stop() {
        generation = UUID(); operation?.cancel(); operation = nil; busy = false
        audio.suspendHandsFree()
        audio.visualRespond = nil; visualConversation?.cancel(); visualConversation = nil
    }
    private func setImage(_ input: UIImage, source: String) {
        stop()
        generation = UUID(); operation?.cancel(); busy = false; result = "Imagem pronta. Ainda não enviada."
        let scale = min(1, 480 / max(input.size.width, input.size.height))
        let size = CGSize(width: max(1, input.size.width*scale), height: max(1, input.size.height*scale))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        let clean = UIGraphicsImageRenderer(size: size, format: format).image { _ in input.draw(in: CGRect(origin: .zero, size: size)) }
        self.image = clean; self.png = clean.pngData(); self.source = source
    }
    private func startVisualConversation() {
        guard let png, !busy else { return }
        stop()
        let imageSource = source
        let context = VisualConversation { question, history in
            try await model.describeImage(png: png, source: imageSource, question: question, history: history).description
        }
        visualConversation = context
        audio.visualRespond = { question in try await context.answer(question) }
        operation = Task { @MainActor in
            await audio.enableHandsFree()
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            stop()
        }
    }
    private func analyze() {
        guard let png, !busy else { return }
        stop()
        busy = true; result = "Analisando a imagem…"
        let id = UUID(); generation = id
        operation = Task { @MainActor in
            defer { if generation == id { busy = false } }
            do {
                let reply = try await model.describeImage(png: png, source: source, question: question)
                guard !Task.isCancelled, generation == id else { return }
                result = reply.description
                audio.speakVisionDescription(reply.description)
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                result = error.localizedDescription
            }
        }
    }
    fileprivate static func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 480,height: 320))
            UIColor.red.setFill(); context.fill(CGRect(x: 45,y: 90,width: 130,height: 130))
            UIColor.blue.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 275,y: 90,width: 130,height: 130))
        }
    }
}
#endif
