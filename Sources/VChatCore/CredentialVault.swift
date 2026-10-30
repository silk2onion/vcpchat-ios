import Foundation
import Security
import LocalAuthentication

/// Credentials never enter UserDefaults, the chat database, source code or diagnostic logs.
public actor CredentialVault {
    private let service: String
    public init(service: String? = nil) { self.service = service ?? Bundle.main.bundleIdentifier ?? "app.vcpchat.native" }
    public enum AccessError: Error { case authorizationRequired }
    public func read(_ name: String, allowingInteraction: Bool = true) throws -> String {
        var value: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = !allowingInteraction
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context]
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if !allowingInteraction && [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) { throw AccessError.authorizationRequired }
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else { throw ClientError.server("无法读取本机钥匙串（\(status)）") }
        return text
    }
    public func save(_ value: String, name: String) throws {
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
}
