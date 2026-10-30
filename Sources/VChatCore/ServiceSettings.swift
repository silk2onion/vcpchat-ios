import Foundation
public struct ServiceSettings: Codable, Sendable, Equatable {
    public var adminUsername = ""
    public var logServer = ""
    public var speech = SpeechSettings()
    enum CodingKeys: String, CodingKey { case adminUsername, logServer, speech }
    public init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); adminUsername = try c.decodeIfPresent(String.self,forKey: .adminUsername) ?? ""; logServer = try c.decodeIfPresent(String.self,forKey: .logServer) ?? ""; speech = try c.decodeIfPresent(SpeechSettings.self,forKey: .speech) ?? SpeechSettings() }
    public init() {}
}
public enum ServiceSecret: String, CaseIterable, Sendable { case adminPassword = "admin-password", speechKey = "speech-key" }
