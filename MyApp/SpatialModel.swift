import Foundation

// All distances are metres in an AR session/map frame. No motion commands exist here.
struct SpatialVector: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var z: Double
    static let zero = Self(x: 0, y: 0, z: 0)
    var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
    func distance(to b: Self) -> Double { sqrt(pow(x-b.x,2)+pow(y-b.y,2)+pow(z-b.z,2)) }
}
struct SpatialTransform: Codable, Equatable, Sendable {
    // Row-major homogeneous transform: destinationFromSource.
    let values: [Double]
    static let identity = Self(values: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
    static func translation(_ p: SpatialVector) -> Self {
        var a = identity.values; a[3]=p.x; a[7]=p.y; a[11]=p.z; return Self(values:a)
    }
    static func rotationY(_ a: Double) -> Self { Self(values:[cos(a),0,sin(a),0, 0,1,0,0, -sin(a),0,cos(a),0, 0,0,0,1]) }
    static func rotationX(_ a: Double) -> Self { Self(values:[1,0,0,0, 0,cos(a),-sin(a),0, 0,sin(a),cos(a),0, 0,0,0,1]) }
    var valid: Bool {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return false }
        let a=values; let e=0.002
        guard abs(a[12])+abs(a[13])+abs(a[14])+abs(a[15]-1)<e else { return false }
        for i in 0..<3 { for j in 0..<3 {
            let dot=(0..<3).reduce(0.0) { $0+a[i*4+$1]*a[j*4+$1] }
            if abs(dot-(i==j ? 1:0))>e { return false }
        } }
        let det=a[0]*(a[5]*a[10]-a[6]*a[9])-a[1]*(a[4]*a[10]-a[6]*a[8])+a[2]*(a[4]*a[9]-a[5]*a[8])
        return abs(det-1)<e
    }
    var position: SpatialVector { valid ? SpatialVector(x:values[3],y:values[7],z:values[11]) : .zero }
    func multiplied(by b: Self) -> Self? {
        guard valid, b.valid else { return nil }
        var c=Array(repeating:0.0,count:16)
        for i in 0..<4 { for j in 0..<4 { for k in 0..<4 { c[i*4+j] += values[i*4+k]*b.values[k*4+j] } } }
        let t=Self(values:c); return t.valid ? t:nil
    }
    var inverse: Self? {
        guard valid else { return nil }; var c=Self.identity.values
        for i in 0..<3 { for j in 0..<3 { c[i*4+j]=values[j*4+i] } }
        for i in 0..<3 { c[i*4+3] = -(c[i*4]*values[3]+c[i*4+1]*values[7]+c[i*4+2]*values[11]) }
        return Self(values:c)
    }
}
enum SpatialTracking: String, Codable, Sendable { case off, initializing, tracking, limited, relocalizing, lost, thermalUnavailable, unavailable }
struct SpatialSnapshot: Codable, Sendable {
    let epoch: UUID
    let mapID: UUID
    let timestamp: Double
    let tracking: SpatialTracking
    let worldFromCamera: SpatialTransform
    let reason: String
    func usable(now: Double, epoch: UUID, mapID: UUID) -> Bool {
        self.epoch==epoch && self.mapID==mapID && tracking == .tracking && worldFromCamera.valid && timestamp.isFinite && now.isFinite && now>=timestamp && now-timestamp<=1
    }
}
struct SpatialHeadSample: Sendable {
    enum Provenance: String, Sendable { case measured, estimated, commanded }
    let timestamp: Double; let pan: Double; let tilt: Double; let provenance: Provenance
    let synchronizedClock: Bool
}
struct SpatialCalibration: Sendable {
    let bodyFromPivot: SpatialTransform
    let pivotFromCameraAtZero: SpatialTransform
    func worldFromBody(snapshot: SpatialSnapshot, head: SpatialHeadSample, now: Double) -> SpatialTransform? {
        guard snapshot.usable(now:now,epoch:snapshot.epoch,mapID:snapshot.mapID), head.synchronizedClock,
              head.provenance == .measured, head.timestamp.isFinite, head.timestamp<=now,
              now-head.timestamp<=0.5, abs(head.timestamp-snapshot.timestamp)<=0.1,
              head.pan.isFinite, head.tilt.isFinite, abs(head.pan)<=Double.pi, abs(head.tilt)<=Double.pi/2,
              let a=bodyFromPivot.multiplied(by:.rotationY(head.pan)),
              let b=a.multiplied(by:.rotationX(head.tilt)),
              let c=b.multiplied(by:pivotFromCameraAtZero), let inverse=c.inverse else { return nil }
        return snapshot.worldFromCamera.multiplied(by:inverse)
    }
}
struct SpatialPlace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID; let name: String; let position: SpatialVector
}
struct SpatialLink: Codable, Equatable, Sendable {
    let a: UUID; let b: UUID
    // Operator-declared connection for route simulation, never measured free space.
}
struct SpatialMap: Codable, Sendable {
    let version: Int
    let id: UUID
    var places: [SpatialPlace]
    var links: [SpatialLink]
    init(id: UUID = UUID()) { version=1; self.id=id; places=[]; links=[] }
    var valid: Bool {
        guard version==1, places.count<=64, links.count<=128, Set(places.map(\.id)).count==places.count else { return false }
        let names=places.map { Self.normalized($0.name) }
        guard Set(names).count==names.count, places.allSatisfy({ !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.utf8.count<=100 && $0.position.finite && $0.position.distance(to:.zero)<=1000 }) else { return false }
        let ids=Set(places.map(\.id)); var pairs=Set<String>()
        for link in links {
            let pair=[link.a.uuidString,link.b.uuidString].sorted().joined()
            guard link.a != link.b, ids.contains(link.a), ids.contains(link.b), pairs.insert(pair).inserted else { return false }
        }
        return true
    }
    static func normalized(_ s: String) -> String { s.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"pt_BR")) }
    mutating func mark(name: String, at snapshot: SpatialSnapshot, now: Double, epoch: UUID) throws {
        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard snapshot.usable(now:now,epoch:epoch,mapID:id), clean.utf8.count<=100, !clean.isEmpty, places.count<64,
              snapshot.worldFromCamera.position.distance(to:.zero)<=1000,
              !places.contains(where:{Self.normalized($0.name)==Self.normalized(clean)}) else { throw SpatialError.invalidPlace }
        places.append(SpatialPlace(id:UUID(),name:clean,position:snapshot.worldFromCamera.position))
    }
    mutating func connect(_ a: UUID, _ b: UUID) throws {
        let edge=SpatialLink(a:a,b:b)
        guard links.count<128, a != b, places.contains(where:{$0.id==a}), places.contains(where:{$0.id==b}),
              !links.contains(where:{($0.a==a && $0.b==b)||($0.a==b && $0.b==a)}) else { throw SpatialError.invalidLink }
        links.append(edge)
    }
    func nearest(to snapshot: SpatialSnapshot, now: Double, epoch: UUID) -> SpatialPlace? {
        guard valid, snapshot.usable(now:now,epoch:epoch,mapID:id) else { return nil }
        return places.filter { $0.position.distance(to:snapshot.worldFromCamera.position)<=0.75 }.min { $0.position.distance(to:snapshot.worldFromCamera.position)<$1.position.distance(to:snapshot.worldFromCamera.position) }
    }
    func route(from start: UUID, to goal: UUID, snapshot: SpatialSnapshot, now: Double, epoch: UUID) throws -> SpatialRoute {
        guard valid, snapshot.usable(now:now,epoch:epoch,mapID:id), let source=places.first(where:{$0.id==start}), places.contains(where:{$0.id==goal}), source.position.distance(to:snapshot.worldFromCamera.position)<=0.75 else { throw SpatialError.localizationRequired }
        var costs=[start:0.0]; var previous=[UUID:UUID](); var pending=Set(places.map(\.id))
        while let u=pending.min(by:{(costs[$0] ?? .infinity)<(costs[$1] ?? .infinity)}), let cost=costs[u] {
            pending.remove(u); if u==goal { break }
            for edge in links where edge.a==u || edge.b==u {
                let v=edge.a==u ? edge.b:edge.a
                guard pending.contains(v), let p=places.first(where:{$0.id==u}), let q=places.first(where:{$0.id==v}) else { continue }
                let candidate=cost+p.position.distance(to:q.position)
                if candidate<(costs[v] ?? .infinity) { costs[v]=candidate; previous[v]=u }
            }
        }
        guard let distance=costs[goal] else { throw SpatialError.noRoute }
        var ids=[goal]; var cursor=goal
        while cursor != start { guard let p=previous[cursor], ids.count<65 else { throw SpatialError.noRoute }; ids.append(p); cursor=p }
        let ordered=ids.reversed().compactMap { id in places.first { $0.id==id } }
        return SpatialRoute(epoch:epoch,mapID:id,createdAt:now,places:ordered,distance:distance)
    }
}
struct SpatialRoute: Sendable {
    let epoch: UUID; let mapID: UUID; let createdAt: Double; let places: [SpatialPlace]; let distance: Double
    let simulatedOnly = true
    let obstacleClearanceVerified = false
}
enum SpatialError: LocalizedError {
    case invalidPlace, invalidLink, localizationRequired, noRoute, invalidArchive, cameraBusy
    var errorDescription: String? {
        switch self {
        case .invalidPlace: return "Lugar inválido, repetido ou rastreamento indisponível."
        case .invalidLink: return "Conexão inválida ou já cadastrada."
        case .localizationRequired: return "Localização recente junto ao ponto de partida necessária."
        case .noRoute: return "Não há conexão cadastrada até esse destino."
        case .invalidArchive: return "Mapa incompatível ou inválido; nenhum dado carregado."
        case .cameraBusy: return "Câmera ocupada. Pare o outro modo antes de ativar."
        }
    }
}
struct SpatialArchive: Codable {
    let graph: SpatialMap
    let worldMap: Data
    let savedAt: Date
    var valid: Bool { graph.valid && !worldMap.isEmpty && worldMap.count<=16_000_000 && savedAt.timeIntervalSince1970.isFinite }
    func encoded() throws -> Data {
        guard valid else { throw SpatialError.invalidArchive }
        return try JSONEncoder().encode(self)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count<=24_000_000 else { throw SpatialError.invalidArchive }
        let a=try JSONDecoder().decode(Self.self,from:data)
        guard a.valid else { throw SpatialError.invalidArchive }; return a
    }
}
// Audit-only admission result. There is deliberately no actuator/transport dependency.
struct SpatialBodyAudit {
    static func report(snapshot: SpatialSnapshot?, now: Double, bodyPose: SpatialTransform?, physicalTransportValidated: Bool, safetyClear: Bool) -> [String] {
        var reasons=["ATUAÇÃO NÃO IMPLEMENTADA NESTE MÓDULO", "Obstáculos, piso e espaço do chassi não validados"]
        let localized=snapshot.map { $0.usable(now:now,epoch:$0.epoch,mapID:$0.mapID) } ?? false
        if !localized { reasons.append("Localização indisponível ou antiga") }
        if bodyPose?.valid != true { reasons.append("Calibração/posição medida do pescoço indisponível") }
        if !physicalTransportValidated { reasons.append("Transporte físico não validado") }
        if !safetyClear { reasons.append("Segurança física não confirmada") }
        return reasons
    }
}
