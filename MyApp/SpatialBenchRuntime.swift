#if canImport(ARKit) && canImport(UIKit)
import Foundation
import ARKit
import AVFoundation
import UIKit
import Combine

/// Live-only publications are observed by small subviews, never by the editable Form.
@MainActor final class SpatialLivePresentation: ObservableObject {
    struct Value {
        let snapshot: SpatialSnapshot?
        let trace: [SpatialVector]
        let lastDeliveryMS: Double
        let peakDeliveryMS: Double
    }
    @Published private(set) var value=Value(snapshot:nil,trace:[],lastDeliveryMS:0,peakDeliveryMS:0)
    func publish(snapshot: SpatialSnapshot?,trace: [SpatialVector],lastDeliveryMS: Double,peakDeliveryMS: Double) {
        value=Value(snapshot:snapshot,trace:trace,lastDeliveryMS:lastDeliveryMS,peakDeliveryMS:peakDeliveryMS)
    }
}

private final class SpatialSessionDelegate: NSObject, ARSessionDelegate, @unchecked Sendable {
    let epoch: UUID
    let receive: @Sendable (UUID, SpatialFrameEvent) -> Void
    let failed: @Sendable (UUID, String) -> Void
    let allowsRelocalization: Bool
    private var lastTime = -Double.infinity
    init(epoch: UUID, allowsRelocalization: Bool, receive: @escaping @Sendable (UUID, SpatialFrameEvent) -> Void, failed: @escaping @Sendable (UUID, String) -> Void) {
        self.epoch=epoch; self.allowsRelocalization=allowsRelocalization; self.receive=receive; self.failed=failed
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARKit tracks at its own rate. Only UI/trace publication is throttled.
        guard frame.timestamp-lastTime>=SpatialFrameDelivery.publicationInterval else { return }; lastTime=frame.timestamp
        let tracking: SpatialTracking; let reason: String
        switch frame.camera.trackingState {
        case .normal: tracking = .tracking; reason = "Referência visual/inercial disponível"
        case .notAvailable: tracking = .lost; reason = "Rastreamento indisponível"
        case .limited(let cause):
            switch cause {
            case .initializing: tracking = .initializing; reason = "Inicializando"
            case .relocalizing: tracking = .relocalizing; reason = "Buscando referência do mapa"
            case .excessiveMotion: tracking = .limited; reason = "Movimento excessivo"
            case .insufficientFeatures: tracking = .limited; reason = "Poucos detalhes visuais"
            @unknown default: tracking = .limited; reason = "Rastreamento limitado"
            }
        }
        let t=frame.camera.transform
        let values=(0..<4).flatMap { row in (0..<4).map { col in Double(t[col][row]) } }
        receive(epoch,SpatialFrameEvent(timestamp:frame.timestamp,pose:SpatialTransform(values:values),tracking:tracking,reason:reason,anchorNames:frame.anchors.compactMap(\.name),mapped:frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending))
    }
    func session(_ session: ARSession, didFailWithError error: Error) { failed(epoch,error.localizedDescription) }
    func sessionWasInterrupted(_ session: ARSession) { failed(epoch,"Sessão interrompida; reinicie ou carregue o mapa explicitamente.") }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { allowsRelocalization }
}

/// Bench only. No TARSRuntime, ESP32 connection, motion command or paid inference.
@MainActor final class SpatialBenchRuntime: ObservableObject {
    static let shared = SpatialBenchRuntime()
    @Published private(set) var active=false
    @Published private(set) var state: SpatialTracking = .off
    @Published private(set) var detail="Bancada: movimente o XR com a mão. Sem atuação física."
    @Published private(set) var graph=SpatialMap()
    private(set) var snapshot: SpatialSnapshot?
    private(set) var trace: [SpatialVector]=[]
    let live=SpatialLivePresentation()
    @Published private(set) var route: SpatialRoute?
    @Published private(set) var busy=false
    @Published private(set) var firmwareEvidence: [SpatialFirmwareEvidence]=[]
    @Published private(set) var diagnosticURL: URL?
    private var epoch=UUID()
    private var session: ARSession?
    private var delegate: SpatialSessionDelegate?
    private var lease: CameraOwnership.Lease?
    private var observers: [NSObjectProtocol]=[]
    private var mapped=false
    private var waitingForMap=false
    private var originAnchorAdded=false
    private var monitor: Task<Void,Never>?
    private var frameConsumer: Task<Void,Never>?
    private var frameSink: AsyncStream<SpatialFrameEvent>.Continuation?
    private var watchdog: SpatialSessionWatchdog?
    private var acceptedFrames=0
    private var lastDeliveryMS=0.0
    private var peakDeliveryMS=0.0
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    var age: Double? { snapshot.map { max(0,now-$0.timestamp) } }
    var localized: Bool { snapshot?.usable(now:now,epoch:epoch,mapID:graph.id) == true && !waitingForMap }
    var nearestName: String { guard let snapshot, localized else { return "Indisponível" }; return graph.nearest(to:snapshot,now:now,epoch:epoch)?.name ?? "Entre pontos cadastrados" }
    var audit: [String] { SpatialBodyAudit.report(snapshot:localized ? snapshot:nil,now:now,bodyPose:nil,physicalTransportValidated:false,safetyClear:false) }
    private var archiveURL: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TARSSpatialBench",isDirectory:true).appendingPathComponent("map-v1.json")
    }
    init() {
        for name in [UIApplication.willResignActiveNotification, ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            let inactive=name==UIApplication.willResignActiveNotification
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.active else { return }
                    if inactive { self.stop(reason:"App inativo; pose invalidada.") }
                    else if let reason=self.block { self.stop(reason:reason,thermal:true) }
                }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; monitor?.cancel(); frameConsumer?.cancel(); frameSink?.finish() }
    private var block: String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Modo de baixo consumo ativo." }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical { return "Temperatura bloqueia percepção espacial." }
        return nil
    }
    func startNew() async { await start(archive:nil) }
    private func start(archive: SpatialArchive?) async {
        guard !active, !busy else { return }; busy=true; defer { busy=false }
        guard ARWorldTrackingConfiguration.isSupported else { state = .unavailable; detail="ARKit world tracking não suportado neste dispositivo."; return }
        guard UIApplication.shared.applicationState == .active, block == nil else { state = .unavailable; detail=block ?? "App inativo."; return }
        guard let token=CameraOwnership.shared.acquire(.spatial) else { detail=SpatialError.cameraBusy.localizedDescription; return }
        lease=token
        // While authorization is pending, stop() can invalidate this attempt.
        let generation=UUID(); epoch=generation
        let allowed=await AVCaptureDevice.requestAccess(for:.video)
        guard epoch==generation, CameraOwnership.shared.lease==token else { return }
        guard allowed else { stop(reason:"Permissão de câmera negada."); state = .unavailable; return }
        guard UIApplication.shared.applicationState == .active, block == nil else { stop(reason:block ?? "App inativo."); return }
        let config=ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [] // No dense mesh, sceneDepth or automatic clearance claim.
        config.isAutoFocusEnabled=true
        if let format=ARWorldTrackingConfiguration.supportedVideoFormats.filter({ $0.framesPerSecond>=30 }).min(by:{
            let a=$0.imageResolution.width*$0.imageResolution.height*Double($0.framesPerSecond)
            let b=$1.imageResolution.width*$1.imageResolution.height*Double($1.framesPerSecond)
            return a<b
        }) { config.videoFormat=format }
        var loadedMap: ARWorldMap?
        if let archive {
            do {
                guard archive.valid else { throw SpatialError.invalidArchive }
                loadedMap=try NSKeyedUnarchiver.unarchivedObject(ofClass:ARWorldMap.self,from:archive.worldMap)
                guard let loadedMap, loadedMap.anchors.contains(where:{$0.name=="tars.map.\(archive.graph.id.uuidString)"}) else { throw SpatialError.invalidArchive }
            } catch { stop(reason:error.localizedDescription); return }
        }
        graph=archive?.graph ?? SpatialMap(); waitingForMap=archive != nil
        config.initialWorldMap=loadedMap
        trace=[]; snapshot=nil; route=nil; mapped=false; originAnchorAdded=archive != nil
        acceptedFrames=0; lastDeliveryMS=0; peakDeliveryMS=0
        live.publish(snapshot:nil,trace:[],lastDeliveryMS:0,peakDeliveryMS:0)
        watchdog=SpatialSessionWatchdog(startedAt:now,restoringSavedMap:archive != nil)
        let ar=ARSession()
        let (frames,sink)=SpatialFrameDelivery.makeStream()
        frameSink=sink
        frameConsumer=Task { [weak self] in
            for await event in frames {
                guard !Task.isCancelled, let self, self.active, self.epoch==generation else { return }
                self.receive(id:generation,event:event)
                await Task.yield()
            }
        }
        let handler=SpatialSessionDelegate(epoch:generation,allowsRelocalization:archive != nil,receive:{ _,event in
            sink.yield(event)
        },failed:{ [weak self] id,message in
            Task { @MainActor [weak self] in
                guard let self, self.epoch==id else { return }; self.stop(reason:message); self.state = .lost
            }
        })
        ar.delegate=handler; ar.delegateQueue=DispatchQueue(label:"tars.spatial.frames")
        session=ar; delegate=handler; active=true; state = .initializing
        detail=waitingForMap ? "Relocalização necessária antes de usar lugares salvos.":"Mapeando referência local. Corpo permanece indisponível."
        ar.run(config,options:[.resetTracking,.removeExistingAnchors])
        monitor=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self, self.active, self.epoch==generation else { return }
                if let reason=self.block { self.stop(reason:reason,thermal:true); return }
                self.checkWatchdog(at:self.now)
            }
        }
    }
    private func receive(id: UUID,event: SpatialFrameEvent) {
        guard active, epoch==id, event.timestamp.isFinite, event.timestamp<=now,
              now-event.timestamp<=1, snapshot.map({event.timestamp>$0.timestamp}) ?? true else { return }
        if waitingForMap, event.tracking == .tracking,
           event.anchorNames.contains("tars.map.\(graph.id.uuidString)") { waitingForMap=false }
        let validTracking=event.pose.valid ? event.tracking:SpatialTracking.lost
        let status: SpatialTracking=waitingForMap && validTracking == .tracking ? .relocalizing:validTracking
        let changed=state != status || snapshot?.reason != event.reason
        snapshot=SpatialSnapshot(epoch:epoch,mapID:graph.id,timestamp:event.timestamp,tracking:status,worldFromCamera:event.pose,reason:event.reason)
        if state != status { state=status }
        mapped=event.mapped; acceptedFrames += 1
        lastDeliveryMS=max(0,(now-event.timestamp)*1000); peakDeliveryMS=max(peakDeliveryMS,lastDeliveryMS)
        watchdog?.observe(status,now:now)
        if status == .tracking {
            if !originAnchorAdded {
                session?.add(anchor:ARAnchor(name:"tars.map.\(graph.id.uuidString)",transform:matrix_identity_float4x4)); originAnchorAdded=true
            }
            let p=event.pose.position
            if trace.last.map({$0.distance(to:p)>0.03}) ?? true { trace.append(p); if trace.count>600 { trace.removeFirst(trace.count-600) } }
            if changed { detail="Pose da câmera disponível. Piso e obstáculos não verificados." }
        } else {
            if route != nil { route=nil }
            if changed { detail=waitingForMap ? "Ainda sem referência confirmada do mapa salvo.":event.reason }
        }
        if let route, now-route.createdAt>1 { self.route=nil }
        live.publish(snapshot:snapshot,trace:trace,lastDeliveryMS:lastDeliveryMS,peakDeliveryMS:peakDeliveryMS)
    }
    private func checkWatchdog(at time: Double) {
        guard var policy=watchdog else { return }
        let outcome=policy.evaluate(now:time,lastFrame:snapshot?.timestamp); watchdog=policy
        switch outcome {
        case .healthy: break
        case .stale:
            if state != .lost { state = .lost; detail="Quadro espacial antigo; localização indisponível." }
            if route != nil { route=nil }
        case .noFrames: stop(reason:"Sem quadros espaciais após 12 segundos."); state = .unavailable
        case .newMapTimedOut: stop(reason:"Novo mapa não estabilizou em 25 segundos. Pare, observe uma área com detalhes e tente novamente."); state = .unavailable
        case .savedMapTimedOut: stop(reason:"Mapa salvo não foi relocalizado em 45 segundos. Nenhuma referência nova foi assumida."); state = .unavailable
        case .recoveryTimedOut: stop(reason:"Rastreamento não recuperado após 20 segundos. Mapa mantido, pose invalidada."); state = .lost
        case .invalidClock: stop(reason:"Relógio espacial inválido; pose descartada."); state = .unavailable
        }
    }
    func stop(reason: String = "Percepção espacial desligada.",thermal: Bool = false) {
        epoch=UUID(); active=false; monitor?.cancel(); monitor=nil
        frameSink?.finish(); frameSink=nil; frameConsumer?.cancel(); frameConsumer=nil; watchdog=nil
        session?.pause(); session?.delegate=nil; session=nil; delegate=nil
        if let lease { CameraOwnership.shared.release(lease) }; lease=nil
        snapshot=nil; route=nil; waitingForMap=false; mapped=false
        state=thermal ? .thermalUnavailable:.off; detail=reason
        live.publish(snapshot:nil,trace:trace,lastDeliveryMS:lastDeliveryMS,peakDeliveryMS:peakDeliveryMS)
    }
    func mark(_ name: String) {
        do { guard let snapshot, localized else { throw SpatialError.localizationRequired }; try graph.mark(name:name,at:snapshot,now:now,epoch:epoch); route=nil; detail="Lugar cadastrado nesta referência. Salve o mapa para persistir." }
        catch { detail=error.localizedDescription }
    }
    func connect(_ a: UUID?,_ b: UUID?) {
        do { guard localized, let a, let b else { throw SpatialError.localizationRequired }; try graph.connect(a,b); route=nil; detail="Conexão declarada para simulação; passagem física não verificada." }
        catch { detail=error.localizedDescription }
    }
    func plan(to destination: UUID?) {
        do {
            guard localized, let snapshot, let destination, let nearest=graph.nearest(to:snapshot,now:now,epoch:epoch) else { throw SpatialError.localizationRequired }
            route=try graph.route(from:nearest.id,to:destination,snapshot:snapshot,now:now,epoch:epoch)
            detail="Percurso simulado criado. Não aciona o robô e não comprova espaço livre."
        } catch { route=nil; detail=error.localizedDescription }
    }
    func save() async {
        guard !busy, localized, mapped, let session else { detail="Mapeie mais detalhes antes de salvar; rastreamento e mapa precisam estar disponíveis."; return }
        busy=true; defer { busy=false }; let generation=epoch; let savedGraph=graph
        do {
            let map: ARWorldMap = try await withCheckedThrowingContinuation { continuation in
                session.getCurrentWorldMap { map,error in
                    if let map { continuation.resume(returning:map) } else { continuation.resume(throwing:error ?? SpatialError.invalidArchive) }
                }
            }
            guard active, generation==epoch, localized, savedGraph.id==graph.id,
                  map.anchors.contains(where:{$0.name=="tars.map.\(savedGraph.id.uuidString)"}) else { throw SpatialError.localizationRequired }
            let bytes=try NSKeyedArchiver.archivedData(withRootObject:map,requiringSecureCoding:true)
            let data=try SpatialArchive(graph:savedGraph,worldMap:bytes,savedAt:Date()).encoded()
            try FileManager.default.createDirectory(at:archiveURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:archiveURL,options:[.atomic,.completeFileProtection])
            detail="Mapa espacial salvo localmente; memória pessoal não alterada."
        } catch { if generation==epoch { detail=error.localizedDescription } }
    }
    func load() async {
        guard !active, !busy else { detail="Pare o modo espacial antes de carregar."; return }
        do {
            let attributes=try FileManager.default.attributesOfItem(atPath:archiveURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 24_000_000 else { throw SpatialError.invalidArchive }
            let archive=try SpatialArchive.decode(Data(contentsOf:archiveURL))
            await start(archive:archive)
        } catch { detail=error.localizedDescription }
    }
    #if DEBUG
    static func runSimulatedChecks() throws -> String {
        func require(_ value: Bool,_ message: String) throws {
            if !value { throw NSError(domain:"SpatialBenchChecks",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        }
        let bench=SpatialBenchRuntime()
        guard let lease=CameraOwnership.shared.acquire(.spatial) else { throw SpatialError.cameraBusy }
        bench.lease=lease; bench.active=true; bench.waitingForMap=true
        let id=bench.epoch; let t=bench.now-0.1
        func event(_ time: Double,tracking: SpatialTracking = .tracking,anchors: [String] = []) -> SpatialFrameEvent {
            SpatialFrameEvent(timestamp:time,pose:.identity,tracking:tracking,reason:"simulated",anchorNames:anchors,mapped:true)
        }
        defer { bench.stop() }
        bench.receive(id:id,event:event(t))
        try require(bench.state == .relocalizing && !bench.localized,"saved map needs matching origin anchor")
        bench.receive(id:id,event:event(t+0.01,anchors:["tars.map.\(bench.graph.id.uuidString)"]))
        try require(bench.localized && bench.trace.count==1,"matching map and normal tracking")
        bench.mark("Origem")
        try require(bench.graph.places.count==1,"actual runtime marks place")
        let confirmation=bench.detail
        bench.receive(id:id,event:event(t+0.015))
        try require(bench.detail==confirmation && bench.live.value.snapshot != nil,"live frame preserves mark confirmation")
        bench.plan(to:bench.graph.places[0].id)
        try require(bench.route?.simulatedOnly == true,"actual runtime route is simulated")
        bench.receive(id:id,event:event(t+0.02,tracking:.limited))
        try require(!bench.localized && bench.route==nil,"limited invalidates route")
        bench.receive(id:UUID(),event:event(t+0.03))
        try require(bench.state == .limited,"stale generation ignored")
        bench.receive(id:id,event:event(t+0.01))
        try require(bench.state == .limited,"out of order ignored")
        bench.watchdog=SpatialSessionWatchdog(startedAt:bench.now-30,restoringSavedMap:false)
        bench.checkWatchdog(at:bench.now)
        try require(!bench.active && bench.state == .unavailable && bench.detail.contains("25 segundos"),"fresh-map timeout ends unavailable, not infinite relocalization")
        try require(bench.graph.places.count==1 && bench.live.value.snapshot==nil,"timeout retains places but clears live pose")
        bench.stop()
        try require(bench.snapshot==nil && bench.route==nil && CameraOwnership.shared.lease==nil,"stop clears pose and camera admission")
        bench.receive(id:id,event:event(t+0.04))
        try require(bench.snapshot==nil && !bench.active,"callback after stop ignored")
        return "PASS: spatial runtime map alignment, places, persistent confirmation, isolated live updates, initialization timeout, retained places, simulated route, loss, stale/out-of-order callbacks and camera lease; simulated frames, no ARSession or device I/O"
    }
    #endif
    func importFirmwareTranscript(_ url: URL) {
        let access=url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max)<=65536 else { throw SpatialError.invalidArchive }
            let values=try SpatialFirmwareEvidence.decodeTranscript(Data(contentsOf:url))
            firmwareEvidence=values
            detail="Registro do firmware importado para auditoria; não é telemetria ao vivo."
        } catch { firmwareEvidence=[]; detail="Não foi possível importar o registro Body V0: \(error.localizedDescription)" }
    }
    func exportDiagnostic() {
        struct Diagnostic: Encodable {
            let schema: Int; let state: String; let snapshot: SpatialSnapshot?; let graph: SpatialMap; let trace: [SpatialVector]; let audit: [String]
            let routeNames: [String]; let simulatedOnly: Bool
            let acceptedFrames: Int; let lastDeliveryMS: Double; let peakDeliveryMS: Double
        }
        do {
            let data=try JSONEncoder().encode(Diagnostic(schema:1,state:state.rawValue,snapshot:snapshot,graph:graph,trace:trace,audit:audit,routeNames:route?.places.map(\.name) ?? [],simulatedOnly:true,acceptedFrames:acceptedFrames,lastDeliveryMS:lastDeliveryMS,peakDeliveryMS:peakDeliveryMS))
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("TARS-espacial-diagnostico.json")
            try data.write(to:url,options:.atomic); diagnosticURL=url; detail="Diagnóstico local pronto para compartilhar; inclui nomes e posições cadastrados."
        } catch { detail=error.localizedDescription }
    }
}
#endif
