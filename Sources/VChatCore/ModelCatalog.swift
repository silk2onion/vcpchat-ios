import Foundation
public struct ModelCatalog: Codable, Sendable, Equatable {
    public var endpoint: String
    public var ids: [String]
    public var updatedAt: Double
    public var recent: [String]
    public init(endpoint: String, ids: [String], recent: [String] = []) {
        self.endpoint = endpoint
        var seen = Set<String>(); self.ids = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.updatedAt = Date().timeIntervalSince1970; self.recent = recent
    }
    public func matches(_ query: String) -> [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.isEmpty { return ids }
        return ids.filter { id in words.allSatisfy { id.localizedCaseInsensitiveContains($0) } }
    }
    public mutating func select(_ id: String) { recent = [id] + recent.filter { $0 != id }; recent = Array(recent.prefix(8)) }
}
