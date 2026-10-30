import Foundation
public struct ServiceSettings: Codable, Sendable, Equatable {
    public var adminUsername = ""
    public var logServer = ""
    enum CodingKeys: String, CodingKey { case adminUsername, logServer }
    public init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); adminUsername = try c.decodeIfPresent(String.self,forKey: .adminUsername) ?? ""; logServer = try c.decodeIfPresent(String.self,forKey: .logServer) ?? "" }
    public init() {}
}
public enum ServiceSecret: String, CaseIterable, Sendable { case adminPassword = "admin-password" }
