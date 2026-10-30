import Foundation

public struct ConnectionConfiguration: Codable, Sendable, Equatable {
    public var server: String
    public var model: String
    public var framesPerSecond: Int
    public init(server: String = "https://agent.sijinworld.com", model: String = "", framesPerSecond: Int = 60) {
        self.server = server; self.model = model; self.framesPerSecond = framesPerSecond
    }
    public func baseURL() throws -> URL {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ClientError.invalidConfiguration }
        return url
    }
    public func endpoint(_ path: String) throws -> URL {
        var base = try baseURL()
        if base.path.hasSuffix("/v1/chat/completions") { base.deleteLastPathComponent(); base.deleteLastPathComponent(); base.deleteLastPathComponent() }
        if base.lastPathComponent == "v1" { base.deleteLastPathComponent() }
        return base.appendingPathComponent(path)
    }
}
public struct ChatTurn: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}
public struct ChatRequest: Sendable {
    public let configuration: ConnectionConfiguration
    public let apiKey: String
    public let messages: [ChatTurn]
    public init(configuration: ConnectionConfiguration, apiKey: String, messages: [ChatTurn]) {
        self.configuration = configuration; self.apiKey = apiKey; self.messages = messages
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
