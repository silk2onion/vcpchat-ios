import Foundation
public struct ServiceSettings: Codable, Sendable, Equatable {
    public var adminUsername = ""
    public var logServer = ""
    public var logsEnabled = false
    public var speech = SpeechSettings()
    public var fileNode = FileNodeSettings()
    public var serverFiles = ServerFileSettings()
    public var sync = MobileSyncSettings()
    public var recallRerank = RecallRerankSettings()
    enum CodingKeys: String, CodingKey { case adminUsername, logServer, logsEnabled, speech, fileNode, serverFiles, sync, recallRerank }
    public init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); adminUsername = try c.decodeIfPresent(String.self,forKey: .adminUsername) ?? ""; logServer = try c.decodeIfPresent(String.self,forKey: .logServer) ?? ""; logsEnabled = try c.decodeIfPresent(Bool.self,forKey: .logsEnabled) ?? false; speech = try c.decodeIfPresent(SpeechSettings.self,forKey: .speech) ?? SpeechSettings(); fileNode = try c.decodeIfPresent(FileNodeSettings.self,forKey: .fileNode) ?? FileNodeSettings(); serverFiles = try c.decodeIfPresent(ServerFileSettings.self,forKey: .serverFiles) ?? ServerFileSettings(); sync = try c.decodeIfPresent(MobileSyncSettings.self,forKey: .sync) ?? MobileSyncSettings(); recallRerank = try c.decodeIfPresent(RecallRerankSettings.self,forKey: .recallRerank) ?? RecallRerankSettings() }
    public init() {}
}
public enum ServiceSecret: String, CaseIterable, Sendable { case recallRerankKey = "recall-rerank-key", adminPassword = "admin-password", speechKey = "speech-key", fileNodeKey = "file-node-key", fileKey = "file-key", syncToken = "sync-token" }
