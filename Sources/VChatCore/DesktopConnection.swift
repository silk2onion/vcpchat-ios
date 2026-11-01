import Foundation

/// Explicit file import, not a filesystem scan. Call only after a system file-picker grant.
public struct DesktopConnection: Sendable {
    public let configuration: ConnectionConfiguration
    public let apiKey: String
    public let logKey: String
    public let preferredModel: String?
    public let syncSettings: MobileSyncSettings?
    public let syncToken: String?
    public static func read(from url: URL) async throws -> DesktopConnection {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ClientError.tooLarge }
        return try DesktopConnection(data: Data(contentsOf: url))
    }
    public init(data: Data) throws {
        struct Pairing: Decodable { let httpURL: String; let socketURL: String; let token: String }
        struct Desktop: Decodable {
            let vcpServerUrl: String; let vcpApiKey: String; let vcpLogKey: String?
            let vchatModel: String?; let vchatMobileSync: Pairing?
        }
        let decoded = try JSONDecoder().decode(Desktop.self, from: data)
        configuration = ConnectionConfiguration(server: decoded.vcpServerUrl)
        _ = try configuration.baseURL()
        guard !decoded.vcpApiKey.isEmpty else { throw ClientError.missingKey }
        apiKey = decoded.vcpApiKey; logKey = decoded.vcpLogKey ?? ""
        preferredModel = decoded.vchatModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferredModel?.isEmpty == true { throw ClientError.invalidConfiguration }
        if let pairing = decoded.vchatMobileSync {
            guard !pairing.token.isEmpty else { throw ClientError.missingKey }
            _ = try MobileSyncSettings.endpoint(pairing.httpURL)
            _ = try MobileSyncSettings.socket(pairing.socketURL,token: pairing.token)
            var settings = MobileSyncSettings()
            settings.httpURL = pairing.httpURL; settings.socketURL = pairing.socketURL
            syncSettings = settings; syncToken = pairing.token
        } else { syncSettings = nil; syncToken = nil }
    }
}
