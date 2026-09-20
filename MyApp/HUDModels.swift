import Foundation

struct HUDField: Codable {
    let value: JSONValue?
    let unit: String?
    let available: Bool
    let source: String
}

enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v) }
    }
}

struct HUDSnapshot: Codable {
    let schemaVersion: String
    let timestamp: Double
    let identity: [String:String]
    let cognition: [String:String]
    let system: [String:String]
    let sensors: [String:HUDField]
    let resources: [String:HUDField]
    let motion: [String:JSONValue]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", timestamp, identity, cognition, system, sensors, resources, motion }
}
