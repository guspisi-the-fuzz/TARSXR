import Foundation

struct TARSCommand: Codable { let intent: String; let action: String; let params: [String: Double] }
struct TARSAPIResponse<T: Decodable>: Decodable { let ok: Bool; let data: T? }

final class TARSClient {
    let baseURL: URL
    private(set) var token: String?
    init(baseURL: URL) { self.baseURL = baseURL }
    func pair(secret: String) async throws {
        var r=URLRequest(url: baseURL.appendingPathComponent("v1/session")); r.httpMethod="POST"; r.setValue("application/json",forHTTPHeaderField:"Content-Type"); r.httpBody=try JSONSerialization.data(withJSONObject:["pairing_secret":secret])
        let (data,_)=try await URLSession.shared.data(for:r); let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any]; let d=obj?["data"] as? [String:Any]; token=d?["token"] as? String
    }
    func request(path: String, method: String="GET", body: Data?=nil) async throws -> Data {
        var r=URLRequest(url:baseURL.appendingPathComponent(path)); r.httpMethod=method; r.httpBody=body; if let token { r.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization") }; if body != nil { r.setValue("application/json",forHTTPHeaderField:"Content-Type") }; return try await URLSession.shared.data(for:r).0
    }
}
