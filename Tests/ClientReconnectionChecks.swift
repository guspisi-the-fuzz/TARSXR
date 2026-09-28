import Foundation

final class StubProtocol: URLProtocol {
    static var code = 201
    static var body = "{\"data\":{\"token\":\"test-token\"}}"
    static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ClientReconnectionChecks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TARSClient(baseURL: URL(string: "https://tars.invalid")!, session: session)
        for status in [401, 403] {
            StubProtocol.code = status
            do { try await client.pair(secret: "test"); preconditionFailure("Must reject") }
            catch TARSClientError.pairingRejected {}
            precondition(client.token == nil)
        }
        StubProtocol.code = 503
        do { try await client.pair(secret: "test"); preconditionFailure("Must fail transiently") }
        catch TARSClientError.unavailable {}
        StubProtocol.code = 201
        try await client.pair(secret: "test")
        precondition(client.token != nil)
        StubProtocol.code = 401
        let before = StubProtocol.calls
        do { _ = try await client.request(path: "v1/hud"); preconditionFailure("Must expire") }
        catch TARSClientError.unauthorized {}
        precondition(client.token == nil && StubProtocol.calls == before + 1)
        StubProtocol.code = 201
        try await client.pair(secret: "test")
        precondition(client.token != nil)
        StubProtocol.code = 503
        StubProtocol.body = "{}"
        let commandStart = StubProtocol.calls
        do { _ = try await client.command("MOVE"); preconditionFailure("Must fail") }
        catch TARSClientError.unavailable {}
        precondition(StubProtocol.calls == commandStart + 1, "Must never retry movement")
        for code in ["AI_INSUFFICIENT_QUOTA", "AI_QUOTA_OR_RATE_LIMIT", "AI_AUTH_FAILED",
                     "AI_ACCESS_DENIED", "AI_LOCAL_LIMIT", "AI_UNCONFIGURED"] {
            precondition(TARSClientError.ai(code).blocksAutomaticVoice)
            StubProtocol.code = 429
            StubProtocol.body = "{\"error\":\"\(code)\"}"
            let start = StubProtocol.calls
            do { _ = try await client.transcribe(data: Data([0])); preconditionFailure("Must fail") }
            catch let error as TARSClientError { precondition(error.blocksAutomaticVoice) }
            precondition(StubProtocol.calls == start + 1)
        }
        precondition(!TARSClientError.ai("AI_RATE_LIMIT").blocksAutomaticVoice)
        precondition(!TARSClientError.unavailable.blocksAutomaticVoice)
        precondition(TARSClientError.pairingRejected.blocksAutomaticVoice)
        StubProtocol.code = 200
        StubProtocol.body = "{\"ok\":true,\"data\":{\"audio\":\"YWJj\",\"format\":\"mp3\"}}"
        let speech = try await client.synthesize(text: "Olá")
        precondition(speech == Data("abc".utf8))
        StubProtocol.body = "{\"ok\":true,\"data\":{\"audio\":\"YWJj\",\"format\":\"unknown\"}}"
        do { _ = try await client.synthesize(text: "Olá"); preconditionFailure("Invalid format") }
        catch TARSClientError.unavailable {}
        let cancellationStart = StubProtocol.calls
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await client.synthesize(text: "Cancelled speech"); preconditionFailure("Must cancel") }
            catch is CancellationError {} catch { preconditionFailure("Wrong error") }
            do { try await client.pair(secret: "test"); preconditionFailure("Must cancel") }
            catch is CancellationError {} catch { preconditionFailure("Wrong error") }
            do { _ = try await client.transcribe(data: Data([0])); preconditionFailure("Must cancel") }
            catch is CancellationError {} catch { preconditionFailure("Wrong error") }
        }.value
        precondition(StubProtocol.calls == cancellationStart, "Cancelled work must not send")
        print("PASS: connection, no movement retry, voice failure classification, cancellation without sends")
    }
}
