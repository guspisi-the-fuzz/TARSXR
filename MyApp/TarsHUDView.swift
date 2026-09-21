import SwiftUI

struct TarsHUDView: View {
    @StateObject var model: TarsHUDViewModel
    @StateObject private var audio = XRAudioController()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                CognitiveDisplay(state: audio.state, level: audio.level)
                    .frame(maxHeight: .infinity)
                AudioControls(audio: audio)
                Rectangle().frame(height: 1).foregroundStyle(.green)
                EngineeringPanel(model: model, audioStatus: audio.status)
                    .frame(maxHeight: .infinity)
            }
            .foregroundStyle(.green)
            .fontDesign(.monospaced)
        }
        .task {
            audio.transcribe = { data in try await model.transcribe(data: data) }
            audio.respond = { text, language in try await model.converse(text: text, language: language) }
            await model.run()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { audio.cancel(message: "Áudio pausado fora do app.") }
        }
        .onDisappear { audio.cancel() }
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
