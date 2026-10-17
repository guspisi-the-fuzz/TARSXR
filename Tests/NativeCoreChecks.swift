import Foundation
@MainActor final class FakeFirmware: TARSRuntime {
    var available=true, safe=true, virtual=true, commands=[String](), recovery=false
    var hudCalls=0
    func hud() async throws -> HUDSnapshot {
        hudCalls += 1
        if !available { throw TARSClientError.unavailable }
        return HUDSnapshot(schemaVersion:"1.0",timestamp:Date().timeIntervalSince1970,identity:[:],cognition:[:],system:["esp32":virtual ? "VIRTUAL":"CONNECTED","safety":safe ? "CLEAR":"STOP"],sensors:[:],resources:[:],motion:[:])
    }
    func command(_ action:String,params:TARSCommandParameters?) async throws -> TARSCommandReply { commands.append(action);if action=="ESTOP" {safe=false};return TARSCommandReply(status:"EXECUTED",reason:"CLEAR",telemetry:nil) }
    func telemetry() async throws -> TARSTelemetry { throw TARSClientError.unavailable }
    func recover() async throws { recovery=true;safe=true }
    func describeImage(png:Data,source:String,question:String,history:[[String:String]]) async throws -> VisionReply { throw TARSClientError.unavailable }
    func transcribe(data:Data) async throws -> String { throw TARSClientError.unavailable }
    func synthesize(text:String) async throws -> Data { throw TARSClientError.unavailable }
    func converse(text:String,language:String,context:[String:Any]?) async throws -> String { preconditionFailure("body must never receive conversation") }
    func streamSpeech(text:String,receive:@escaping @MainActor(Data)throws->Void) async throws { preconditionFailure("body must never receive speech") }
    func streamConversation(text:String,receive:@escaping @MainActor(Data)throws->Void,receiveText:@escaping @MainActor(String)->Void) async throws { preconditionFailure("body must never receive conversation") }
}
@main struct NativeCoreChecks {
    @MainActor static func main() async throws {
        let firmware=FakeFirmware(), body=NativeBodyCore(bridge:FakeFirmware())
        _=try await body.hud(); precondition(body.state == .idle)
        let controller=NativeBodyCore(bridge:firmware)
        _=try await controller.command("MOVE",params:.init(direction:"forward",speed:0.1,durationMS:250))
        precondition(firmware.commands==["MOVE"])
        _=try await controller.command("ESTOP",params:nil)
        do { _=try await controller.command("MOVE",params:.init(direction:"forward",speed:0.1));preconditionFailure() } catch TARSClientError.rejected(let reason) { precondition(reason=="SAFETY_STOP_LATCHED") }
        precondition(firmware.commands==["MOVE","ESTOP"])
        try await controller.recover();precondition(controller.state == .idle && firmware.recovery)
        firmware.available=false
        do { _=try await controller.hud();preconditionFailure() } catch {}
        firmware.available=true
        _=try await controller.hud();precondition(controller.state == .safetyStop)
        try await controller.recover()
        firmware.virtual=false
        do { _=try await controller.command("MOVE",params:.init(direction:"forward",speed:0.1));preconditionFailure() } catch TARSClientError.rejected(let reason) { precondition(reason=="PHYSICAL_TRANSPORT_NOT_VALIDATED") }
        let offline=FakeFirmware();offline.available=false
        let ai=NativeAIService { ("test-only","gpt-5.4-mini") }
        let runtime=NativeAIRuntime(body:offline,ai:ai,observationClock:{0})
        let hud=try await runtime.hud()
        precondition(hud.system["core"]=="XR_NATIVE" && hud.system["esp32"]=="UNAVAILABLE" && hud.system["safety"]=="UNKNOWN")
        let explanation = try await runtime.converse(text:"Você consegue andar pra frente?", language:"pt", context:nil)
        precondition(explanation.contains("bloqueado") && offline.commands.isEmpty)
        for _ in 0..<100 {
            let repeated=try await runtime.hud()
            precondition(repeated.system["core"]=="XR_NATIVE" && repeated.system["safety"]=="UNKNOWN")
        }
        precondition(offline.hudCalls==1, "offline HUD refreshes must respect backoff")
        _=try await runtime.command("STOP",params:nil)
        precondition(offline.commands==["STOP"], "STOP must bypass observation backoff")
        let clearBridge=FakeFirmware()
        let clearRuntime=NativeAIRuntime(body:clearBridge,ai:ai,observationClock:{0})
        let beforeStop=try await clearRuntime.hud()
        precondition(beforeStop.system["safety"]=="CLEAR")
        _=try await clearRuntime.command("ESTOP",params:nil)
        let afterStop=try await clearRuntime.hud()
        precondition(afterStop.system["safety"] != "CLEAR", "cached pre-ESTOP CLEAR cannot reappear")
        precondition(clearBridge.commands==["ESTOP"])
        let virtualRuntime = NativeAIRuntime(body:firmware,ai:ai)
        firmware.virtual=true
        let capabilities = try await virtualRuntime.converse(text:"Quais comandos do ESP32?",language:"pt",context:nil)
        precondition(capabilities.contains("simulados") && capabilities.contains("não executou"))
        var minutePrecision=false
        var quoteMismatch=false
        let now=Date(timeIntervalSince1970:1791460800)
        let lookup=NativePublicLookup(now:{now}) { url in
            if url.host=="query1.finance.yahoo.com" {
                return ["chart":["error":NSNull(),"result":[["meta":["symbol":quoteMismatch ? "VALE3.SA":"PETR4.SA","currency":"BRL","regularMarketPrice":54.33,"regularMarketTime":now.timeIntervalSince1970-600]]]]]
            }
            let fixture:[String:Any] = ["date":minutePrecision ? "2026-10-09T21:30Z" : "2026-10-09T21:30:00Z","timeValid":true,"competitions":[["timeValid":true,"status":["type":["name":"STATUS_SCHEDULED","completed":false]],"competitors":[["team":["id":"2029","displayName":"Palmeiras"]],["team":["id":"9967","displayName":"Bahia"]]]]]]
            return ["status":"success","team":["id":"2029"],"events":[fixture]]
        }
        let price=await lookup.answer("Qual a cotação da PETR4?")!
        precondition(price.contains("54,33 reais") && price.contains("pode ter atraso"))
        quoteMismatch=true
        let wrong=await lookup.answer("Qual a cotação da PETR4?")!
        precondition(wrong.contains("Não consegui confirmar"))
        let game=await lookup.answer("Palmeiras joga em 9 de outubro de 2026?")!
        precondition(game.contains("Bahia") && game.contains("9 de outubro de 2026"))
        minutePrecision=true
        let next=await lookup.answer("Que dia que o Palmeiras joga então?")!
        precondition(next.contains("Bahia") && next.contains("próximo jogo"))
        _=await lookup.answer("Vai haver alguma partida de futebol amanhã?")
        let teamAnswer=await lookup.answer("Palmeiras")!
        precondition(teamAnswer.contains("Bahia"))
        let source=await lookup.answer("Você só consulta a ESPN?")!
        precondition(source.contains("apenas a ESPN"))
        let music=await lookup.answer("Toca o jogo da vida")
        precondition(music==nil)
        print("PASS: native Core offline HUD backoff, direct STOP during retry, pre-ESTOP cache invalidation, latch/recovery, no physical movement, Core alive without Mac, native quote identity and sports date selection")
    }
}
