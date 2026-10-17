import Foundation
@main enum SpatialBenchChecks {
    @MainActor static func main() throws {
        var count=0
        func check(_ value: Bool,_ message: String) { count+=1; precondition(value,message) }
        func near(_ a: SpatialTransform?,_ b: SpatialTransform,_ message: String) {
            check(a.map { zip($0.values,b.values).allSatisfy { abs($0-$1)<0.00001 } } ?? false,message)
        }
        func rejects(_ message: String,_ body: () throws -> Void) { do { try body(); check(false,message) } catch { check(true,message) } }
        let e=UUID(); let mapID=UUID()
        func snap(_ p: SpatialVector = .zero,time: Double = 10,tracking: SpatialTracking = .tracking,epoch: UUID = e,id: UUID = mapID) -> SpatialSnapshot {
            SpatialSnapshot(epoch:epoch,mapID:id,timestamp:time,tracking:tracking,worldFromCamera:.translation(p),reason:"fixture")
        }
        check(SpatialTransform.identity.valid,"identity")
        check(!SpatialTransform(values:[]).valid,"invalid dimensions")
        var broken=SpatialTransform.identity.values; broken[0] = .nan
        check(!SpatialTransform(values:broken).valid,"nan")
        broken=SpatialTransform.identity.values; broken[0] = -1
        check(!SpatialTransform(values:broken).valid,"reflection is not rotation")
        broken=SpatialTransform.identity.values; broken[0] = 2
        check(!SpatialTransform(values:broken).valid,"scale is not rigid")
        broken=SpatialTransform.identity.values; broken[12]=1
        check(!SpatialTransform(values:broken).valid,"projective matrix rejected")
        check(SpatialTransform(values:[]).inverse==nil,"invalid inverse")
        check(SpatialTransform.identity.multiplied(by:SpatialTransform(values:[]))==nil,"invalid composition")
        let offset=SpatialTransform.translation(SpatialVector(x:0.2,y:0.4,z:0.1))
        let calibration=SpatialCalibration(bodyFromPivot:.translation(SpatialVector(x:0,y:0.3,z:0)),pivotFromCameraAtZero:offset)
        let body=SpatialTransform.translation(SpatialVector(x:3,y:0,z:2)).multiplied(by:.rotationY(0.6))!
        for n in 0..<60 {
            let pan=Double(n-30)/15; let tilt=Double(n-30)/30
            let c=calibration.bodyFromPivot.multiplied(by:.rotationY(pan))!.multiplied(by:.rotationX(tilt))!.multiplied(by:offset)!
            let camera=body.multiplied(by:c)!
            let sample=SpatialSnapshot(epoch:e,mapID:mapID,timestamp:10,tracking:.tracking,worldFromCamera:camera,reason:"fixture")
            let head=SpatialHeadSample(timestamp:10,pan:pan,tilt:tilt,provenance:.measured,synchronizedClock:true)
            near(calibration.worldFromBody(snapshot:sample,head:head,now:10.1),body,"head moves while body stays fixed")
            near(camera.multiplied(by:camera.inverse!),.identity,"rigid inverse")
        }
        for provenance in [SpatialHeadSample.Provenance.commanded,.estimated] {
            let head=SpatialHeadSample(timestamp:10,pan:0,tilt:0,provenance:provenance,synchronizedClock:true)
            check(calibration.worldFromBody(snapshot:snap(),head:head,now:10)==nil,"commanded/estimated angle not measured")
        }
        for head in [SpatialHeadSample(timestamp:9,pan:0,tilt:0,provenance:.measured,synchronizedClock:true),SpatialHeadSample(timestamp:10,pan:0,tilt:0,provenance:.measured,synchronizedClock:false),SpatialHeadSample(timestamp:11,pan:0,tilt:0,provenance:.measured,synchronizedClock:true),SpatialHeadSample(timestamp:10,pan:.nan,tilt:0,provenance:.measured,synchronizedClock:true)] {
            check(calibration.worldFromBody(snapshot:snap(),head:head,now:10)==nil,"unusable head telemetry")
        }
        for state in [SpatialTracking.off,.initializing,.limited,.relocalizing,.lost,.thermalUnavailable,.unavailable] { check(!snap(tracking:state).usable(now:10,epoch:e,mapID:mapID),"bad tracking") }
        check(!snap().usable(now:11.1,epoch:e,mapID:mapID),"stale pose")
        check(!snap().usable(now:9,epoch:e,mapID:mapID),"future pose")
        check(!snap().usable(now:.nan,epoch:e,mapID:mapID),"invalid clock")
        check(!snap().usable(now:10,epoch:UUID(),mapID:mapID),"old epoch")
        check(!snap().usable(now:10,epoch:e,mapID:UUID()),"different map")
        var map=SpatialMap(id:mapID)
        try map.mark(name:"Sala",at:snap(),now:10,epoch:e)
        try map.mark(name:"Corredor",at:snap(SpatialVector(x:1,y:0,z:0)),now:10,epoch:e)
        try map.mark(name:"Cozinha",at:snap(SpatialVector(x:2,y:0,z:0)),now:10,epoch:e)
        try map.mark(name:"Isolado",at:snap(SpatialVector(x:2,y:0,z:2)),now:10,epoch:e)
        check(map.valid,"valid places")
        rejects("normalized duplicate") { try map.mark(name:" SALA ",at:snap(),now:10,epoch:e) }
        rejects("empty name") { try map.mark(name:"  ",at:snap(),now:10,epoch:e) }
        rejects("long name") { try map.mark(name:String(repeating:"á",count:70),at:snap(),now:10,epoch:e) }
        rejects("stale mark") { try map.mark(name:"Other",at:snap(),now:12,epoch:e) }
        rejects("wrong map") { try map.mark(name:"Other",at:snap(id:UUID()),now:10,epoch:e) }
        let a=map.places[0].id,b=map.places[1].id,c=map.places[2].id,d=map.places[3].id
        rejects("self link") { try map.connect(a,a) }
        rejects("missing endpoint") { try map.connect(a,UUID()) }
        try map.connect(a,b); try map.connect(b,c)
        rejects("reverse duplicate") { try map.connect(b,a) }
        let route=try map.route(from:a,to:c,snapshot:snap(),now:10,epoch:e)
        check(route.places.map(\.name)==["Sala","Corredor","Cozinha"],"ordered route")
        check(abs(route.distance-2)<0.0001,"geometry distance")
        check(route.simulatedOnly && !route.obstacleClearanceVerified,"no clearance/motion authority")
        rejects("disconnected map") { _ = try map.route(from:a,to:d,snapshot:snap(),now:10,epoch:e) }
        rejects("not near source") { _ = try map.route(from:b,to:c,snapshot:snap(),now:10,epoch:e) }
        rejects("stale route request") { _ = try map.route(from:a,to:c,snapshot:snap(),now:12,epoch:e) }
        rejects("old session route") { _ = try map.route(from:a,to:c,snapshot:snap(),now:10,epoch:UUID()) }
        check(map.nearest(to:snap(),now:10,epoch:e)?.id==a,"near known point")
        check(map.nearest(to:snap(SpatialVector(x:20,y:0,z:0)),now:10,epoch:e)==nil,"unknown region")
        check(map.nearest(to:snap(tracking:.limited),now:10,epoch:e)==nil,"tracking limited")
        let same=try map.route(from:a,to:a,snapshot:snap(),now:10,epoch:e)
        check(same.places.count==1 && same.distance==0,"already at point")
        let bytes=try SpatialArchive(graph:map,worldMap:Data([1,2,3]),savedAt:Date()).encoded()
        let loaded=try SpatialArchive.decode(bytes)
        check(loaded.graph.id==mapID && loaded.graph.places==map.places && loaded.graph.links==map.links,"archive roundtrip")
        rejects("malformed archive") { _ = try SpatialArchive.decode(Data("{}".utf8)) }
        rejects("empty worldmap") { _ = try SpatialArchive(graph:map,worldMap:Data(),savedAt:Date()).encoded() }
        var invalid=map; invalid.links.append(SpatialLink(a:a,b:UUID()))
        check(!invalid.valid,"dangling persisted edge")
        invalid=map; invalid.places.append(map.places[0]); check(!invalid.valid,"duplicate persisted id")
        rejects("invalid graph archive") { _ = try SpatialArchive(graph:invalid,worldMap:Data([1]),savedAt:Date()).encoded() }
        let audit=SpatialBodyAudit.report(snapshot:snap(),now:10,bodyPose:.identity,physicalTransportValidated:true,safetyClear:true)
        check(audit.contains("ATUAÇÃO NÃO IMPLEMENTADA NESTE MÓDULO"),"even all inputs do not enable movement")
        check(SpatialBodyAudit.report(snapshot:nil,now:10,bodyPose:nil,physicalTransportValidated:false,safetyClear:false).count==6,"missing body conditions")
        let owner=CameraOwnership()
        let vision=owner.acquire(.vision)!
        check(owner.acquire(.spatial)==nil && owner.acquire(.photo)==nil,"exclusive camera")
        owner.release(CameraOwnership.Lease(id:UUID(),mode:.vision)); check(owner.lease==vision,"stale release ignored")
        owner.release(vision); let spatial=owner.acquire(.spatial)!
        check(owner.acquire(.vision)==nil && owner.acquire(.photo)==nil,"spatial excludes still and video")
        owner.release(vision); check(owner.lease==spatial,"previous owner cannot release new owner")
        owner.release(spatial); let photo=owner.acquire(.photo)!
        check(owner.acquire(.spatial)==nil,"photo excludes spatial"); owner.release(photo)
        check(owner.lease==nil,"release after stop")
        print("PASS: \(count) spatial transforms, head/body separation, freshness, map isolation, places, simulated routes, archive validation, read-only body audit and camera ownership checks. Synthetic data; no ARKit precision, firmware, camera, API or physical motion tested.")
    }
}
