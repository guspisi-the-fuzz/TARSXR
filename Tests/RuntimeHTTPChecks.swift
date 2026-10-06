import Foundation

/// Runs only on macOS, using the real TARSClient and URLProtocol (no real network).
private final class RuntimeHTTPStub: URLProtocol {
    static var requests: [(String, String, String?)] = []
    static var commandStatus = 200
    static var pairingStatus = 201
    static var conversationBody: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append((path, request.httpMethod ?? "", request.value(forHTTPHeaderField: "Authorization")))
        var status = 200
        let body: String
        switch path {
        case "/v1/session":
            status = Self.pairingStatus
            body = #"{"ok":true,"data":{"token":"test-session"}}"#
        case "/v1/hud":
            body = #"{"ok":true,"data":{"schema_version":"1.0","timestamp":1,"identity":{},"cognition":{},"system":{"esp32":"UNAVAILABLE","safety":"STOP"},"sensors":{},"resources":{},"motion":{"active":false}}}"#
        case "/v1/command":
            status = Self.commandStatus
            body = status == 200
                ? #"{"ok":true,"data":{"status":"accepted","reason":"fixture"}}"#
                : #"{"ok":false,"data":{"reason":"SAFETY_STOP_LATCHED"}}"#
        case "/v1/interaction":
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    precondition(n >= 0, "Request body stream failed")
                    if n == 0 { break }
                    data.append(contentsOf: buffer.prefix(n))
                }
            }
            Self.conversationBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            body = #"{"ok":true,"data":{"speech":"Olá"}}"#
        default:
            preconditionFailure("Unexpected endpoint: \(path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct RuntimeHTTPChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuntimeHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = TARSClient(baseURL: URL(string: "https://tars.invalid")!, session: session)
        let runtime: any TARSRuntime = RemoteTARSRuntime(client: client, pairingSecret: "fixture")
        let snapshot = try await runtime.hud()
        check(snapshot.system["esp32"] == "UNAVAILABLE", "Real client HUD decoding")
        check(RuntimeHTTPStub.requests.map { $0.0 } == ["/v1/session", "/v1/hud"], "Pair before first HUD")
        check(RuntimeHTTPStub.requests[0].1 == "POST" && RuntimeHTTPStub.requests[1].1 == "GET", "HTTP methods preserved")
        check(RuntimeHTTPStub.requests[1].2 == "Bearer test-session", "Bearer retained")
        _ = try await runtime.hud()
        check(RuntimeHTTPStub.requests.filter { $0.0 == "/v1/session" }.count == 1, "No redundant pairing")
        let speech = try await runtime.converse(text: "oi", language: "pt-BR", context: ["internal_wake_summary": true])
        check(speech == "Olá", "Concrete conversation response")
        check(RuntimeHTTPStub.conversationBody["mode"] as? String == "mind" && RuntimeHTTPStub.conversationBody["text"] as? String == "oi", "Existing interaction payload")
        check((RuntimeHTTPStub.conversationBody["context"] as? [String: Any])?["internal_wake_summary"] as? Bool == true, "Wake context reaches HTTP")
        // The existing client accepts a language argument but does not serialize it here.
        // Migration preserves that contract; no new wire behavior is invented in this patch.
        check(RuntimeHTTPStub.conversationBody["language"] == nil, "No accidental wire-format change")
        RuntimeHTTPStub.commandStatus = 409
        let before = RuntimeHTTPStub.requests.count
        do { _ = try await runtime.command("MOVE"); preconditionFailure("Rejected motion accepted") }
        catch TARSClientError.rejected(let reason) { check(reason == "SAFETY_STOP_LATCHED", "Safety reason preserved") }
        check(RuntimeHTTPStub.requests.count == before + 1, "Failed command is not replayed")
        RuntimeHTTPStub.commandStatus = 401
        do { _ = try await runtime.command("MOVE"); preconditionFailure("Expired session accepted") }
        catch TARSClientError.unauthorized { count += 1 }
        check(client.token == nil, "401 expires concrete client token")
        let expiredCount = RuntimeHTTPStub.requests.count
        _ = try await runtime.hud()
        check(RuntimeHTTPStub.requests.count == expiredCount + 2, "Next HUD pairs once, without replaying MOVE")
        print("PASS: \(count) concrete HTTP/runtime checks (URLProtocol; no real network)")
    }
}
