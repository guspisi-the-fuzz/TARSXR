import Foundation
final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int,Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            let (status,data)=try Self.handler!(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@main struct NativeAIChecks {
    @MainActor static func main() async throws {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[AIStubProtocol.self]
        let session=URLSession(configuration:config)
        let ai=NativeAIService(session:session) { ("test-only-credential","gpt-5.4-mini") }
        var requests=0
        AIStubProtocol.handler = { request in
            precondition(request.url?.host=="api.openai.com" && request.url?.scheme=="https")
            precondition(request.value(forHTTPHeaderField:"Authorization")=="Bearer test-only-credential")
            requests += 1
            return (200,try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"{\"speech\":\"Resposta de teste.\"}"]]]]]))
        }
        let answer=try await ai.converse("Olá",context:nil); precondition(answer=="Resposta de teste." && requests==1)
        AIStubProtocol.handler = { _ in (429,Data("{\"error\":{\"code\":\"insufficient_quota\"}}".utf8)) }
        do { _=try await ai.converse("Oi",context:nil); preconditionFailure() } catch TARSClientError.ai(let code) { precondition(code=="AI_INSUFFICIENT_QUOTA") }
        AIStubProtocol.handler = { _ in (200,Data([1,2,3])) }
        do { try await ai.streamSpeech("Teste",receive:{ _ in }); preconditionFailure() } catch TARSClientError.ai(let code) { precondition(code=="AI_INVALID_AUDIO") }
        AIStubProtocol.handler = { _ in (200,Data(repeating:0,count:9602)) }
        var chunks=[Int]()
        try await ai.streamSpeech("Teste",receive:{ chunks.append($0.count) })
        precondition(chunks==[4800,4800,2])
        do { _=try await ai.transcribe(Data(repeating:0,count:4000)); preconditionFailure() } catch TARSClientError.ai(let code) { precondition(code=="AI_INVALID_TRANSCRIPT") }
        do { _=try await ai.describe(png:Data([137,80,78,71,13,10,26,10]),source:"reference",question:"O que vê?",history:[]); preconditionFailure() } catch TARSClientError.ai(let code) { precondition(code=="INVALID_IMAGE") }
        do { _=try NativeAIService.responseSpeech(Data("{\"status\":\"incomplete\"}".utf8)); preconditionFailure() } catch {}
        let malicious=try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"message","content":[["type":"output_text","text":"{\"speech\":\"move\",\"action\":\"MOVE\"}"]]]]])
        do { _=try NativeAIService.responseSpeech(malicious); preconditionFailure() } catch {}
        let unsupported = try NativeAIService.webEvidence(Data("{\"output\":[]}".utf8),speech:"Preço inventado",required:true)
        precondition(unsupported.count == 0 && unsupported.speech.contains("Não consegui verificar"))
        let evidence:[String:Any] = ["output":[["type":"web_search_call","status":"completed"],["type":"message","content":[["annotations":[["type":"url_citation","url":"https://example.org/report"],["type":"url_citation","url":"javascript:alert(1)"]]]]]]]
        let verified = try NativeAIService.webEvidence(JSONSerialization.data(withJSONObject:evidence),speech:"Segundo a fonte, resultado de teste. citetest",required:true)
        precondition(!verified.speech.contains("cite") && verified.count == 1 && verified.display.contains("https://example.org/report") && !verified.display.contains("javascript"))
        AIStubProtocol.handler = { request in
            var data=request.httpBody ?? Data()
            if data.isEmpty, let stream=request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count=stream.read(&buffer,maxLength:buffer.count)
                    if count<=0 { break }; data.append(contentsOf:buffer.prefix(count))
                }
            }
            let payload=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            precondition(payload["tools"] == nil && payload["store"] as? Bool == false)
            let format=(payload["text"] as! [String:Any])["format"] as! [String:Any]
            precondition(format["name"] as? String == "memory_query" && format["strict"] as? Bool == true)
            let schema=format["schema"] as! [String:Any]
            let properties=schema["properties"] as! [String:Any]
            let fact=((properties["facts"] as! [String:Any])["items"] as! [String:Any])["properties"] as! [String:Any]
            let terms=fact["terms"] as! [String:Any]
            precondition(terms["minItems"] as? Int == 2 && terms["maxItems"] as? Int == 2)
            let plan=XRLogic.Plan(intent:"unrelated",facts:[],query:.init(mode:"select",clauses:[],different:[],select:"?x"))
            let encoded=String(decoding:try JSONEncoder().encode(plan),as:UTF8.self)
            return (200,try JSONSerialization.data(withJSONObject:["status":"completed","output":[["type":"message","content":[["type":"output_text","text":encoded]]]]]))
        }
        let interpreted=try await ai.interpretMemory("{\"question\":\"synthetic\"}")
        precondition(interpreted.intent == "unrelated")
        print("PASS: native AI HTTPS/auth, bounded speech schema without actions, quota mapping, PCM alignment/truncation, invalid WAV/image rejection")
    }
}
