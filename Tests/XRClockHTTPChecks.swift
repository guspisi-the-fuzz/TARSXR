import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Real request serialization through URLProtocol; never uses a real Core or network.
private final class ClockHTTPStub: URLProtocol {
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

@main struct XRClockHTTPChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClockHTTPStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var seconds = 1791303593.0
        var clockReads = 0
        let client = TARSClient(baseURL: URL(string: "https://tars.invalid")!, session: session, deviceClock: {
            clockReads += 1
            return XRDeviceClock.snapshot(now: Date(timeIntervalSince1970: seconds), timeZone: TimeZone(secondsFromGMT: -10800)!)
        })
        let runtime: any TARSRuntime = RemoteTARSRuntime(client: client, pairingSecret: "test-only")
        _ = try await runtime.converse(text: "Que horas são?", language: "pt-BR", context: ["internal_wake_summary": true, "device_clock": ["source": "forged"]])
        check(ClockHTTPStub.paths == ["/v1/session", "/v1/interaction"], "existing remote route")
        let body = ClockHTTPStub.bodies.last!
        let context = body["context"] as! [String: Any]
        let clock = context["device_clock"] as! [String: Any]
        check(body["mode"] as? String == "mind", "Mind preserved")
        check(body["text"] as? String == "Que horas são?", "question unchanged")
        check(context["internal_wake_summary"] as? Bool == true, "other context preserved")
        check(clock["source"] as? String == "xr_system_clock", "caller cannot supply old or forged snapshot")
        check(clock["unix_seconds"] as? Double == seconds, "device value reaches serialized request")
        check(clock["utc_offset_seconds"] as? Int == -10800, "offset reaches request")
        check(clockReads == 1, "one capture per request")
        seconds += 60
        _ = try await runtime.converse(text: "What time is it?", language: "en-US", context: nil)
        let next = ClockHTTPStub.bodies.last!
        let nextContext = next["context"] as! [String: Any]
        check((nextContext["device_clock"] as! [String: Any])["unix_seconds"] as? Double == seconds, "next turn refreshes clock")
        check(next["text"] as? String == "What time is it?", "English request preserved")
        check(nextContext["internal_wake_summary"] == nil, "no context retained from earlier turn")
        check(clockReads == 2, "no snapshot cache")
        check(ClockHTTPStub.paths.filter { $0 == "/v1/session" }.count == 1, "no extra pairing")
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.converse(text: "hours", language: "en-US", context: nil)
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled request accepted") }
        catch is CancellationError { count += 1 }
        check(clockReads == 2 && ClockHTTPStub.paths.count == 3, "cancellation sends nothing and reads no clock")
        check(!ClockHTTPStub.paths.contains("/v1/command") && !ClockHTTPStub.paths.contains("/v1/recover"), "no actuator or recovery endpoint")
        print("PASS: \(count) XR clock HTTP checks (URLProtocol; no real network or hardware)")
    }
}
