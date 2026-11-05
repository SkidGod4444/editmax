import Foundation
import Security

/// API keys for the "API key" chat backend, one per provider slot (anthropic, openai, google, xai), in the login
/// keychain. The provider's environment variable wins when set. Keys only ever go to codemax (`configure.api.keys`),
/// which hands them to the provider; they are redacted from every log.
enum KeychainStore {
    private static let service = "io.openhorizon.editmax"
    static let slots = ["anthropic", "openai", "google", "xai"]
    static let envNames = ["anthropic": "ANTHROPIC_API_KEY", "openai": "OPENAI_API_KEY", "google": "GOOGLE_GENERATIVE_AI_API_KEY", "xai": "XAI_API_KEY"]

    private static func account(_ slot: String) -> String { "\(slot)-api-key" }

    static func key(_ slot: String) -> String? {
        if let env = envNames[slot].flatMap({ ProcessInfo.processInfo.environment[$0] }), !env.isEmpty { return env }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account(slot), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(data: d, encoding: .utf8) ?? ""
        return s.isEmpty ? nil : s
    }

    /// "environment" when the variable is set, "keychain" when saved, "" when there is none.
    static func source(_ slot: String) -> String {
        if let env = envNames[slot].flatMap({ ProcessInfo.processInfo.environment[$0] }), !env.isEmpty { return "environment" }
        return key(slot) == nil ? "" : "keychain"
    }

    /// Every slot that has a key, for codemax.
    static var allKeys: [String: String] {
        var out: [String: String] = [:]
        for s in slots { if let k = key(s) { out[s] = k } }
        return out
    }

    @discardableResult
    static func save(_ key: String, slot: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(slot)]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base; add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
