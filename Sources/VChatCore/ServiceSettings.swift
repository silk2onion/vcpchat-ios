import Foundation
public struct ServiceSettings: Codable, Sendable, Equatable {
    public var adminUsername = ""
    public var logServer = ""
    public var speech = SpeechSettings()
    public var fileNode = FileNodeSettings()
    enum CodingKeys: String, CodingKey { case adminUsername, logServer, speech, fileNode }
    public init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); adminUsername = try c.decodeIfPresent(String.self,forKey: .adminUsername) ?? ""; logServer = try c.decodeIfPresent(String.self,forKey: .logServer) ?? ""; speech = try c.decodeIfPresent(SpeechSettings.self,forKey: .speech) ?? SpeechSettings(); fileNode = try c.decodeIfPresent(FileNodeSettings.self,forKey: .fileNode) ?? FileNodeSettings() }
    public init() {}
}
public enum ServiceSecret: String, CaseIterable, Sendable { case adminPassword = "admin-password", speechKey = "speech-key", fileNodeKey = "file-node-key" }
