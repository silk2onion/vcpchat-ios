import Foundation
import Security

/// Credentials never enter UserDefaults, the chat database, source code or diagnostic logs.
public actor CredentialVault {
    public enum Persistence: String, Sendable { case keychain, session }
    public nonisolated let persistence: Persistence
    private let service: String
    private var sessionValues: [String: String]
    public init(service: String? = nil, persistence: Persistence = .keychain, sessionValues: [String: String] = [:]) {
        self.service = service ?? Bundle.main.bundleIdentifier ?? "app.vcpchat.native"
        self.persistence = persistence; self.sessionValues = sessionValues
    }
    public enum AccessError: Error { case authorizationRequired }
    public func read(_ name: String, allowingInteraction: Bool = true) throws -> String {
        if persistence == .session { return sessionValues[name] ?? "" }
        guard allowingInteraction else { throw AccessError.authorizationRequired }
        var value: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else { throw ClientError.server("无法读取本机钥匙串（\(status)）") }
        return text
    }
    public func save(_ value: String, name: String) throws {
        if persistence == .session { if value.isEmpty { sessionValues.removeValue(forKey: name) } else { sessionValues[name] = value }; return }
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary
        if value.isEmpty { let status = SecItemDelete(query); guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw ClientError.server("无法清除钥匙串密钥（\(status)）") }; return }
        let attributes = [kSecValueData: Data(value.utf8)] as CFDictionary
        let status = SecItemUpdate(query, attributes)
        if status == errSecItemNotFound {
            var item = query as! [CFString: Any]; item[kSecValueData] = Data(value.utf8); item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw ClientError.server("无法保存钥匙串密钥（\(added)）") }
        } else if status != errSecSuccess { throw ClientError.server("无法更新钥匙串密钥（\(status)）") }
    }
    /// Explicit settings action only. Return failed accounts instead of claiming a partial
    /// Keychain deletion succeeded; the caller also discards its in-memory values.
    public func remove(_ names: [String]) -> [String] {
        names.filter { name in do { try save("",name: name); return false } catch { return true } }
    }
}
