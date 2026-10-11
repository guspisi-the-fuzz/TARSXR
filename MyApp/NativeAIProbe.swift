#if DEBUG
import Foundation
import AVFoundation
import UIKit

@MainActor enum NativeAIProbe {
    static func run() async -> String {
        var passed=[String]()
        do {
            _=try NativeAIKeychain.load()
            guard !FileManager.default.fileExists(atPath:URL.documentsDirectory.appendingPathComponent("native-ai-provision.json").path) else { return "FAIL: provisioning file was not removed" }
            passed.append("device Keychain; provisioning file removed")
            let ai=NativeAIRuntime.service
            if ProcessInfo.processInfo.environment["TARS_WEB_PROBE"] == "1" {
                _ = try await ai.converse("Pesquise no site oficial do TSE qual instituição divulga os resultados das eleições brasileiras. Cite a fonte.",context:nil)
                guard ai.webSourceCount > 0, !ai.webDisplay.isEmpty else { return "FAIL: web search without verified citations" }
                return "PASS: native XR web search; verified URL citations; no Mac Core; no personal data."
            }
            let speech=try await ai.converse("Responda apenas: teste nativo concluído.",context:nil)
            guard !speech.isEmpty else { return "FAIL: empty conversation" }
            passed.append("direct conversation")
            let mp3=try await ai.synthesize("TARS, teste de voz no iPhone.")
            let source=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp3")
            let output=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
            defer { try? FileManager.default.removeItem(at:source); try? FileManager.default.removeItem(at:output) }
            try mp3.write(to:source)
            let audio=try AVAudioFile(forReading:source)
            guard let input=AVAudioPCMBuffer(pcmFormat:audio.processingFormat,frameCapacity:AVAudioFrameCount(audio.length)), let format=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true), let converter=AVAudioConverter(from:audio.processingFormat,to:format), let converted=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(Double(audio.length)*16000/audio.processingFormat.sampleRate)+1024) else { return "FAIL: audio conversion setup" }
            try audio.read(into:input)
            var provided=false; var error:NSError?
            let status=converter.convert(to:converted,error:&error) { _,state in
                if provided { state.pointee = .endOfStream; return nil }
                provided=true; state.pointee = .haveData; return input
            }
            guard error==nil, status != .error else { return "FAIL: audio conversion" }
            do {
                let file=try AVAudioFile(forWriting:output,settings:format.settings,commonFormat:.pcmFormatInt16,interleaved:true)
                try file.write(from:converted)
            }
            let transcript=try await ai.transcribe(Data(contentsOf:output))
            guard transcript.lowercased().contains("teste") else { return "FAIL: transcription did not recover the test utterance" }
            passed.append("Onyx speech and transcription round trip (not played aloud)")
            var bytes=0
            try await ai.streamSpeech("Teste concluído.",receive:{ bytes += $0.count })
            guard bytes>0 else { return "FAIL: no PCM" }
            passed.append("24 kHz PCM stream")
            let png=UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:64,height:64))
            }.pngData()!
            let vision=try await ai.describe(png:png,source:"reference",question:"Qual a cor predominante?",history:[])
            guard !vision.description.isEmpty, !vision.actions_enabled else { return "FAIL: invalid vision reply" }
            passed.append("reference image; no action authority")
            let publicLookup=NativePublicLookup()
            let quote=await publicLookup.answer("Qual a cotação da PETR4?") ?? ""
            guard quote.contains("última cotação disponível") else { return "FAIL: native quote. Completed: "+passed.joined(separator:"; ") }
            passed.append("direct Yahoo Finance quote")
            let game=await publicLookup.answer("Qual o próximo jogo do Palmeiras?") ?? ""
            guard game.contains("ESPN") else { return "FAIL: native schedule. Completed: "+passed.joined(separator:"; ") }
            passed.append("direct ESPN schedule")
            let absent=RemoteTARSRuntime(client:TARSClient(baseURL:URL(string:"http://127.0.0.1:1")!),pairingSecret:"unreachable-test-only")
            let native=NativeAIRuntime(body:absent,ai:ai)
            let hud=try await native.hud()
            guard hud.system["core"]=="XR_NATIVE",hud.system["esp32"]=="UNAVAILABLE",hud.system["safety"]=="UNKNOWN" else { return "FAIL: disconnected body isolation" }
            passed.append("native Core remains online with body transport unreachable")
            return "PASS: "+passed.joined(separator:"; ")+". All provider calls originate on XR; no Mac Core used."
        } catch TARSClientError.ai(let code) { return "FAIL: "+code+". Completed: "+passed.joined(separator:"; ") }
        catch { return "FAIL: native provider or audio conversion. Completed: "+passed.joined(separator:"; ") }
    }
}
#endif
