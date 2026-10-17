#if canImport(ARKit) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

struct SpatialBenchControls: View {
    @ObservedObject private var spatial=SpatialBenchRuntime.shared
    @State private var showsPanel=false
    var body: some View {
        HStack {
            Button("Bancada espacial") { showsPanel=true }.buttonStyle(.bordered)
            if spatial.active { Text("ESPACIAL: \(spatial.state.rawValue.uppercased())").font(.caption2) }
        }
        .sheet(isPresented:$showsPanel) { SpatialBenchPanel(spatial:spatial) }
    }
}
private struct SpatialBenchPanel: View {
    @ObservedObject var spatial: SpatialBenchRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var importingFirmware=false
    @State private var name=""
    @State private var from: UUID?
    @State private var to: UUID?
    @State private var destination: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section("4A · Referência espacial da câmera") {
                    Text("Bancada, sem comandos físicos. Pare a visão local antes de ativar este modo. Ao fechar este painel, a sessão espacial para.")
                    HStack {
                        Button("Novo mapa") { Task { await spatial.startNew() } }.disabled(spatial.active || spatial.busy)
                        Button("Parar") { spatial.stop() }
                    }
                    Text(spatial.detail)
                    Text("Corpo: indisponível · referência: \(spatial.graph.id.uuidString.prefix(8))")
                    SpatialLiveTelemetry(live:spatial.live,state:spatial.state,graph:spatial.graph,route:spatial.route)
                }
                Section("4B · Lugares nesta referência") {
                    TextField("Nome do ponto, ex.: entrada da cozinha",text:$name)
                    Button("Marcar posição atual da câmera") { spatial.mark(name) }.disabled(!spatial.localized || spatial.busy)
                    SpatialNearestPlace(live:spatial.live,graph:spatial.graph)
                    ForEach(spatial.graph.places) { place in Text(place.name) }
                    Button("Salvar mapa e lugares neste XR") { Task { await spatial.save() } }.disabled(!spatial.localized || spatial.busy)
                    Button("Carregar mapa salvo e relocalizar") { Task { await spatial.load() } }.disabled(spatial.active || spatial.busy)
                }
                Section("4C · Conexões e percurso simulado") {
                    placePicker("De",selection:$from)
                    placePicker("Até",selection:$to)
                    Button("Declarar conexão para simulação") { spatial.connect(from,to) }.disabled(!spatial.localized || spatial.busy)
                    Text("Conecte apenas pontos cujo percurso você conhece. Comprimento mostrado é geométrico entre pontos; curvas exigem pontos intermediários.").font(.caption)
                    placePicker("Destino",selection:$destination)
                    Button("Simular percurso do ponto próximo") { spatial.plan(to:destination) }.disabled(!spatial.localized || spatial.busy)
                    if let route=spatial.route {
                        Text(route.places.map(\.name).joined(separator:" → "))
                        Text(String(format:"%.2f m entre pontos · simulado · expira em 1 s",route.distance))
                    }
                    Text("Nenhuma verificação de obstáculos, piso, escadas ou espaço do chassi.")
                }
                SpatialWheelBenchView()
                Section("4D · Auditoria de integração do corpo") {
                    ForEach(spatial.audit,id:\.self) { Text($0) }
                    Button("Importar registro Body V0 para auditoria") { importingFirmware=true }
                    ForEach(Array(spatial.firmwareEvidence.enumerated()),id:\.offset) { _,evidence in
                        Text(evidence.summary)
                        Text("Uptime de origem: \(evidence.sourceUptimeMS) ms · histórico, sem sincronização")
                        ForEach(evidence.issues,id:\.self) { Text($0).font(.caption) }
                    }
                    Text("Este painel não se conecta ao ESP32. Firmware, sensores e segurança física exigem auditoria e teste próprios.")
                    Button("Preparar diagnóstico para compartilhar") { spatial.exportDiagnostic() }
                    if let url=spatial.diagnosticURL { ShareLink("Compartilhar diagnóstico",item:url) }
                }
            }
            .navigationTitle("Percepção em bancada")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Fechar") { spatial.stop(); dismiss() } } }
        }
        .fileImporter(isPresented:$importingFirmware,allowedContentTypes:[.json,.plainText]) { result in
            if case .success(let url)=result { spatial.importFirmwareTranscript(url) }
        }
        .onDisappear { spatial.stop() }
    }
    private func placePicker(_ label: String,selection: Binding<UUID?>) -> some View {
        Picker(label,selection:selection) {
            Text("Selecione").tag(Optional<UUID>.none)
            ForEach(spatial.graph.places) { p in Text(p.name).tag(Optional(p.id)) }
        }
    }
}
/// Only this live region observes frame publications. Name/route editors do not.
private struct SpatialLiveTelemetry: View {
    @ObservedObject var live: SpatialLivePresentation
    let state: SpatialTracking
    let graph: SpatialMap
    let route: SpatialRoute?
    var body: some View {
        let value=live.value
        VStack(alignment:.leading,spacing:8) {
            TimelineView(.periodic(from:.now,by:1)) { _ in
                let now=ProcessInfo.processInfo.systemUptime
                Text("\(state.rawValue.uppercased()) · quadro: \(value.snapshot.map { String(format:"%.1f s",max(0,now-$0.timestamp)) } ?? "indisponível")")
            }
            if let snapshot=value.snapshot, snapshot.usable(now:ProcessInfo.processInfo.systemUptime,epoch:snapshot.epoch,mapID:graph.id) {
                let p=snapshot.worldFromCamera.position
                Text(String(format:"Câmera: x %.2f · y %.2f · z %.2f m",p.x,p.y,p.z))
            }
            SpatialTraceView(points:value.trace,places:graph.places,route:route?.places ?? [],cameraPose:state == .tracking ? value.snapshot?.worldFromCamera:nil).frame(height:200)
            Text("Vista superior x/z relativa. A linha registra a câmera; não representa chão livre.").font(.caption)
            Text(String(format:"Entrega do quadro: %.0f ms · pico %.0f ms",value.lastDeliveryMS,value.peakDeliveryMS)).font(.caption2)
        }
    }
}
private struct SpatialNearestPlace: View {
    @ObservedObject var live: SpatialLivePresentation
    let graph: SpatialMap
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { _ in
            let value=live.value
            if let snapshot=value.snapshot, snapshot.usable(now:ProcessInfo.processInfo.systemUptime,epoch:snapshot.epoch,mapID:graph.id) {
                Text("Ponto próximo: \(graph.nearest(to:snapshot,now:ProcessInfo.processInfo.systemUptime,epoch:snapshot.epoch)?.name ?? "Entre pontos cadastrados")")
            } else { Text("Ponto próximo: Indisponível") }
        }
    }
}
private struct SpatialTraceView: View {
    let points: [SpatialVector]; let places: [SpatialPlace]; let route: [SpatialPlace]
    let cameraPose: SpatialTransform?
    var body: some View {
        Canvas(rendersAsynchronously:true) { context,size in
            let all=points+places.map(\.position)
            let minX=(all.map(\.x).min() ?? 0)-0.5; let maxX=(all.map(\.x).max() ?? 0)+0.5
            let minZ=(all.map(\.z).min() ?? 0)-0.5; let maxZ=(all.map(\.z).max() ?? 0)+0.5
            let scale=min((size.width-24)/(maxX-minX),(size.height-24)/(maxZ-minZ))
            func point(_ p: SpatialVector) -> CGPoint { CGPoint(x:12+(p.x-minX)*scale,y:12+(p.z-minZ)*scale) }
            func path(_ values: [SpatialVector]) -> Path {
                var p=Path(); for (i,v) in values.enumerated() { if i==0 { p.move(to:point(v)) } else { p.addLine(to:point(v)) } }; return p
            }
            context.stroke(path(points),with:.color(.cyan),lineWidth:2)
            if let pose=cameraPose, pose.valid {
                let origin=point(pose.position)
                let dx = -pose.values[2]; let dz = -pose.values[10]; let length=hypot(dx,dz)
                context.fill(Path(ellipseIn:CGRect(x:origin.x-5,y:origin.y-5,width:10,height:10)),with:.color(.cyan))
                if length>0.01 {
                    var facing=Path(); facing.move(to:origin)
                    facing.addLine(to:CGPoint(x:origin.x+20*dx/length,y:origin.y+20*dz/length))
                    context.stroke(facing,with:.color(.cyan),lineWidth:4)
                }
            }
            context.stroke(path(route.map(\.position)),with:.color(.orange),style:StrokeStyle(lineWidth:3,dash:[5,4]))
            for place in places {
                let p=point(place.position)
                context.fill(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.green))
                context.draw(Text(place.name).font(.caption2),at:CGPoint(x:p.x,y:p.y+12))
            }
        }
    }
}
#endif
