import Foundation
import Security

/// Credentials never enter UserDefaults, the chat database, source code or diagnostic logs.
public actor CredentialVault {
    private let service: String
    public init(service: String = "app.vcpchat.native") { self.service = service }
    public func read(_ name: String) throws -> String {
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else { throw ClientError.server("无法读取本机钥匙串（\(status)）") }
        return text
    }
    public func save(_ value: String, name: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: name] as CFDictionary
        if value.isEmpty { let status = SecItemDelete(query); guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw ClientError.server("无法清除钥匙串密钥") }; return }
        let attributes = [kSecValueData: Data(value.utf8)] as CFDictionary
        let status = SecItemUpdate(query, attributes)
        if status == errSecItemNotFound {
            var item = query as! [CFString: Any]; item[kSecValueData] = Data(value.utf8); item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ClientError.server("无法保存钥匙串密钥") }
        } else if status != errSecSuccess { throw ClientError.server("无法更新钥匙串密钥") }
    }
}
