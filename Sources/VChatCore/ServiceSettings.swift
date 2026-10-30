import Foundation
public struct ServiceSettings: Codable, Sendable, Equatable {
    public var adminUsername = ""
    public init() {}
}
public enum ServiceSecret: String, CaseIterable, Sendable { case adminPassword = "admin-password" }
