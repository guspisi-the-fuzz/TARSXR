import Foundation
import Security

/// Device-owned credentials. No API credential is compiled into the application.
@MainActor enum NativeAIKeychain {
    struct Configuration: Codable { let key: String; let model: String }
    private static var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.pisi.tarsxr.native-ai", kSecAttrAccount as String:"openai"] }
    static func load() throws -> Configuration {
        var q = query; q[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { throw TARSClientError.ai("AI_UNCONFIGURED") }
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
    #if DEBUG
    static func diagnosticStatus() -> OSStatus {
        var q = query
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil)
    }

    /// One-time development provisioning into this device's Keychain. Import file is removed.
    static func importProvisioning() throws {
        let url = URL.documentsDirectory.appendingPathComponent("native-ai-provision.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return }
        defer { try? FileManager.default.removeItem(at:url) }
        let data = try Data(contentsOf:url)
        guard data.count < 16384 else { throw TARSClientError.ai("AI_UNCONFIGURED") }
        let config = try JSONDecoder().decode(Configuration.self, from:data)
        guard config.key.hasPrefix("sk-"), config.key.count > 20, !config.model.isEmpty else { throw TARSClientError.ai("AI_UNCONFIGURED") }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if updated == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw TARSClientError.ai("AI_UNCONFIGURED") }
        } else if updated != errSecSuccess { throw TARSClientError.ai("AI_UNCONFIGURED") }
    }
    #endif
}
