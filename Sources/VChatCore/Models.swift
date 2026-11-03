import Foundation

public enum EndpointMode: String, Codable, CaseIterable, Sendable {
    case standard
    case vcpTools = "vcp-tools"
    public var title: String { self == .standard ? "OpenAI 兼容" : "VCP 工具模式" }
}
public struct ConnectionConfiguration: Codable, Sendable, Equatable {
    public var server: String
    public var model: String
    public var framesPerSecond: Int
    public var endpointMode: EndpointMode
    public var temperature: Double
    public var sendTemperature: Bool
    public init(server: String = "https://agent.sijinworld.com", model: String = "", framesPerSecond: Int = 60, endpointMode: EndpointMode = .standard, temperature: Double = 0.8, sendTemperature: Bool = false) {
        self.server = server; self.model = model; self.framesPerSecond = framesPerSecond
        self.endpointMode = endpointMode; self.temperature = temperature; self.sendTemperature = sendTemperature
    }
    enum CodingKeys: String, CodingKey { case server, model, framesPerSecond, endpointMode, temperature, sendTemperature }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(server: try c.decode(String.self, forKey: .server), model: try c.decodeIfPresent(String.self, forKey: .model) ?? "", framesPerSecond: try c.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? 60, endpointMode: try c.decodeIfPresent(EndpointMode.self, forKey: .endpointMode) ?? .standard, temperature: try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.8, sendTemperature: try c.decodeIfPresent(Bool.self, forKey: .sendTemperature) ?? false)
    }
    public func baseURL() throws -> URL {
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { $0.value <= 31 }), !raw.contains("#") else { throw ClientError.invalidConfiguration }
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil else { throw ClientError.invalidConfiguration }
        return url
    }
    public func endpoint(_ path: String) throws -> URL {
        let url = try baseURL()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil; components.fragment = nil
        var base = components.url!
        if base.path.hasSuffix("/v1/chat/completions") || base.path.hasSuffix("/v1/chatvcp/completions") { base.deleteLastPathComponent(); base.deleteLastPathComponent(); base.deleteLastPathComponent() }
        if base.lastPathComponent == "v1" { base.deleteLastPathComponent() }
        return base.appendingPathComponent(path)
    }
    public func chatEndpoint() throws -> URL { try endpoint(endpointMode == .vcpTools ? "v1/chatvcp/completions" : "v1/chat/completions") }
}
public struct ChatTurn: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public var parts: [APIContentPart]?
    public init(role: String, content: String, attachments: [ChatAttachment] = []) {
        self.role = role; self.content = content
        let value = AttachmentContext.parts(text: content, attachments: attachments)
        if value.contains(where: { $0.type == "image_url" }) { parts = value }
        else { parts = nil; if !attachments.isEmpty { self.content = value.first?.text ?? content } }
    }
    enum CodingKeys: String, CodingKey { case role, content }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(role, forKey: .role)
        if let parts { try c.encode(parts, forKey: .content) } else { try c.encode(content, forKey: .content) }
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); role = try c.decode(String.self, forKey: .role)
        if let value = try? c.decode(String.self, forKey: .content) { content = value; parts = nil }
        else { let value = try c.decode([APIContentPart].self, forKey: .content); parts = value; content = value.compactMap(\.text).joined(separator: "\n\n") }
    }
}
public struct ChatRequest: Sendable {
    public let configuration: ConnectionConfiguration
    public let apiKey: String
    public let messages: [ChatTurn]
    public let temperature: Double?
    public let contextTokenLimit: Int?
    public let maxOutputTokens: Int?
    public init(configuration: ConnectionConfiguration, apiKey: String, messages: [ChatTurn], temperature: Double? = nil, contextTokenLimit: Int? = nil, maxOutputTokens: Int? = nil) {
        self.configuration = configuration; self.apiKey = apiKey; self.messages = messages; self.temperature = temperature
        self.contextTokenLimit = contextTokenLimit; self.maxOutputTokens = maxOutputTokens
    }
}
public enum SessionState: String, Codable, Sendable { case connecting, streaming, complete, stopped, interrupted, failed }
public struct SessionUpdate: Sendable {
    public let state: SessionState
    public let text: String
    public let reasoning: String
    public let sequence: Int
    public let rawEvents: Int
    public let parserWasOffMainThread: Bool
}
public struct PushUpdate: Sendable {
    public let connected: Bool
    public let kind: String
    public let text: String
    public var payload: JSONValue = .null
}
public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, missingKey, missingModel, http(Int), invalidResponse, interrupted, tooLarge, server(String), authentication, timeout
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "服务器地址无效，请填写 http 或 https 地址"
        case .missingKey: "请填写聊天 API Key"
        case .missingModel: "请填写模型 ID，或先刷新模型"
        case .http(let status): "服务器返回 HTTP \(status)"
        case .invalidResponse: "服务器返回了无法识别的数据"
        case .interrupted: "连接已中断，已收到的内容保留"
        case .tooLarge: "单条回复超过 8 MB，已保留收到的内容"
        case .server(let text): text
        case .authentication: "WebSocket 鉴权失败，请检查 VCPLog Key"
        case .timeout: "连接超时，请检查服务器"
        }
    }
}
