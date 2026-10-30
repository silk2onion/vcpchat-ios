import Foundation
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .null: try c.encodeNil() } }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { v[key] ?? .null } else { .null } }
    public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var text: String { switch self { case .string(let v): v; case .number(let v): v == v.rounded() && abs(v) < 9e15 ? String(Int64(v)) : String(v); default: "" } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var pretty: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return (try? encoder.encode(self)).map { String(decoding: $0,as: UTF8.self) } ?? "" }
}
public actor VCPHTTP {
    private let session: URLSession
    public init() { let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 30; session = URLSession(configuration: config) }
    public func json(_ url: URL, method: String = "GET", authorization: String = "", body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: url); request.httpMethod = method
        if !authorization.isEmpty { request.setValue(authorization,forHTTPHeaderField: "Authorization") }
        request.setValue("application/json",forHTTPHeaderField: "Accept")
        if let body { request.setValue("application/json",forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
        guard data.count <= 20_000_000 else { throw ClientError.server("服务器响应超过 20 MB") }
        if data.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(JSONValue.self,from: data)
    }
}
