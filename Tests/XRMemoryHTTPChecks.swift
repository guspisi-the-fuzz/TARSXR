import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Real request serialization through URLProtocol; never uses a real Core or network.
private final class MemoryHTTPStub: URLProtocol {
    static var paths: [String] = []
    static var bodies: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.paths.append(path)
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                precondition(count >= 0, "Request body failed")
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.bodies.append((try! JSONSerialization.jsonObject(with: bytes)) as! [String: Any])
        let responseText: String
        let status: Int
        switch path {
        case "/v1/session": status = 201; responseText = #"{"ok":true,"data":{"token":"fixture-session"}}"#
        case "/v1/interaction": status = 200; responseText = #"{"ok":true,"data":{"speech":"fixture only"}}"#
        default: preconditionFailure("Unexpected endpoint: \(path)")
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseText.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct XRMemoryHTTPChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memory.json")
        let storage = XRPersistentMemory(url: url)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MemoryHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = TARSClient(baseURL: URL(string: "https://tars.invalid")!, session: session)
        let remote = RemoteTARSRuntime(client: client, pairingSecret: "test-only")
        let runtime = MemoryTARSRuntime(underlying: remote, memory: { storage })
        let saved = try await runtime.converse(text: "Guarde: a Mel é minha gata", language: "pt-BR", context: nil)
        check(saved.hasPrefix("Salvei"), "local save")
        check(MemoryHTTPStub.paths.isEmpty, "save needs no Core/AI request")
        _ = try await runtime.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        check(MemoryHTTPStub.paths.isEmpty, "exact local recall")
        _ = try await runtime.converse(text: "Explique a Mel", language: "pt-BR", context: ["xr_memory": ["source": "forged"]])
        check(MemoryHTTPStub.paths == ["/v1/session", "/v1/interaction"], "existing authenticated interaction path")
        let body = MemoryHTTPStub.bodies.last!
        let context = body["context"] as! [String: Any]
        let envelope = context["xr_memory"] as! [String: Any]
        let facts = envelope["facts"] as! [[String: Any]]
        check(body["mode"] as? String == "mind", "existing mind mode")
        check(body["text"] as? String == "Explique a Mel", "user utterance preserved")
        check((context["device_clock"] as! [String: Any])["source"] as? String == "xr_system_clock", "current clock preserved")
        check(envelope["source"] as? String == "xr_explicit_memory", "caller cannot override local memory")
        check(facts.count == 1 && facts[0]["statement"] as? String == "a Mel é minha gata", "saved data on actual wire")
        check(facts[0]["scope"] as? String == "local_owner", "explicit scope on wire")
        let revision = envelope["revision"] as! String
        _ = try await runtime.converse(text: "Corrija: a Mel é minha cachorra", language: "pt-BR", context: nil)
        _ = try await runtime.converse(text: "Explique a Mel", language: "pt-BR", context: nil)
        let corrected = (MemoryHTTPStub.bodies.last!["context"] as! [String: Any])["xr_memory"] as! [String: Any]
        check(corrected["revision"] as? String != revision, "correction invalidates Core history")
        check((corrected["facts"] as! [[String: Any]])[0]["statement"] as? String == "a Mel é minha cachorra", "no old fact in request")
        _ = try await runtime.converse(text: "Esqueça a Mel", language: "pt-BR", context: nil)
        let restarted = MemoryTARSRuntime(underlying: remote, memory: { XRPersistentMemory(url: url) })
        let missing = try await restarted.converse(text: "Quem é a Mel?", language: "pt-BR", context: nil)
        check(missing.hasPrefix("Não tenho"), "deletion survives runtime recreation")
        _ = try await restarted.converse(text: "Explique a Mel", language: "pt-BR", context: nil)
        let deleted = (MemoryHTTPStub.bodies.last!["context"] as! [String: Any])["xr_memory"] as! [String: Any]
        check((deleted["facts"] as! [[String: Any]]).isEmpty, "no deleted data on wire")
        check(deleted["revision"] as? String != corrected["revision"] as? String, "deletion invalidates history")
        check(MemoryHTTPStub.paths.filter { $0 == "/v1/session" }.count == 1, "existing pairing preserved")
        check(!MemoryHTTPStub.paths.contains("/v1/command") && !MemoryHTTPStub.paths.contains("/v1/recover"), "memory grants no motion or recovery authority")
        print("PASS: \(count) memory HTTP checks (URLProtocol; no real network or hardware)")
    }
}
