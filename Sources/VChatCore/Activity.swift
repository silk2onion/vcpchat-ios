import Foundation
public enum PushChannel: String, Codable, Sendable, CaseIterable { case log, info
    public var title: String { self == .log ? "VCPLog" : "VCPInfo" }
}
public enum ActivityKind: String, Sendable, CaseIterable { case all, handled, approval, rag, thinking, agent, memory, dream, notification, error, log
    public var title: String { switch self { case .all: "全部"; case .handled: "已处理"; case .approval: "待审批"; case .rag: "RAG 知识库"; case .thinking: "元思考链"; case .agent: "Agent 会话"; case .memory: "记忆检索"; case .dream: "Agent 梦境"; case .notification: "通知"; case .error: "错误"; case .log: "VCPLog" } }
    public var icon: String { switch self { case .approval: "checkmark.shield"; case .rag: "cylinder.split.1x2"; case .thinking: "brain"; case .agent: "person.2"; case .memory: "note.text"; case .dream: "moon"; case .error: "exclamationmark.circle"; case .log: "waveform.path"; default: "bell" } }
}
public struct ActivityEntry: Codable, Sendable, Identifiable, Equatable {
    public struct Decision: Codable, Sendable, Equatable { public var approved: Bool; public var reason: String; public var sentAt: Double }
    public var id = UUID().uuidString
    public var channel: PushChannel
    public var payload: JSONValue
    public var createdAt = Date().timeIntervalSince1970
    public var seen = false
    public var decision: Decision?
    public var logPresentation: ActivityLogPresentation?
    public init(channel: PushChannel, payload: JSONValue) { self.channel = channel; self.payload = payload; logPresentation = ActivityLogPresentation(payload: payload) }
    mutating func prepareLogPresentation() { logPresentation = ActivityLogPresentation(payload: payload) }
    public var data: JSONValue { .object(payload.object.merging(payload["data"].object,uniquingKeysWith: { _,b in b })) }
    public var requestID: String { data["requestId"].text }
    public var kind: ActivityKind {
        let d = data, type = d["type"].text
        if ["tool_approval_request","tool_approval_response"].contains(type) { return .approval }
        if type == "RAG_RETRIEVAL_DETAILS" || { if case .array = d["results"] { true } else { false } }() { return .rag }
        if type == "META_THINKING_CHAIN" { return .thinking }
        if type == "AGENT_PRIVATE_CHAT_PREVIEW" || d["source"].text == "AgentAssistant" { return .agent }
        if let presentation = logPresentation {
            switch presentation.category { case .notification: return .notification; case .error: return .error; case .log: break }
        }
        if ["AI_MEMO_RETRIEVAL","DailyNote"].contains(type) { return .memory }
        if type.hasPrefix("AGENT_DREAM_") { return .dream }
        if type.range(of: "error|fail",options: [.regularExpression,.caseInsensitive]) != nil || d["level"].text == "error" || d["status"].text == "error" { return .error }
        if ["notification","daily_note_created","video_generation_status"].contains(type) { return .notification }
        return .log
    }
    public var title: String {
        if let presentation = logPresentation { return presentation.title }
        let d = data
        let keys: [String] = switch kind { case .approval: d["type"].text == "tool_approval_response" ? [] : ["toolName"]; case .rag: ["dbName"]; case .thinking: ["chainName","title"]; case .agent: ["agentName","sender","maid"]; case .memory: ["dbName","title","agentName"]; case .dream: ["title","agentName"]; default: ["title","message","toolName","type"] }
        return keys.map { d[$0].text }.first(where: { !$0.isEmpty }) ?? (d["type"].text == "tool_approval_response" ? "审批回执" : kind.title)
    }
    public func expired(now: Double = Date().timeIntervalSince1970) -> Bool {
        let value = data["expiresAt"] == .null ? data["expireAt"] : data["expiresAt"]
        if let millis = value.number { return millis <= now * 1000 }
        guard !value.text.isEmpty else { return false }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let date = parser.date(from: value.text) ?? ISO8601DateFormatter().date(from: value.text)
        return date.map { $0.timeIntervalSince1970 <= now } ?? false
    }
    public func approvalStatus(in entries: [Self], now: Double = Date().timeIntervalSince1970) -> String {
        if let answer = entries.first(where: { $0.data["type"].text == "tool_approval_response" && $0.requestID == requestID && !requestID.isEmpty }) { return answer.data["approved"].bool == true ? "已允许" : "已拒绝" }
        if entries.contains(where: { $0.requestID == requestID && $0.decision != nil }) { return "已发送 · 等待确认" }
        return expired(now: now) ? "已过期" : "待审批"
    }
    public static func response(requestID: String, approved: Bool, reason: String) throws -> JSONValue {
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.server("审批缺少 requestId") }
        var data: [String: JSONValue] = ["requestId": .string(requestID),"approved": .bool(approved)]
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { data["reason"] = .string(String(reason.prefix(1000))) }
        return .object(["type": .string("tool_approval_response"),"data": .object(data)])
    }
}
public enum SocketEndpoint {
    public static func url(server: String, key: String, channel: PushChannel) throws -> URL {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError.missingKey }
        // Node's raw path comparison supports these RFC3986 pchar characters without re-encoding.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@")
        guard key.unicodeScalars.allSatisfy(allowed.contains) else { throw ClientError.server("WebSocket 密钥包含不支持的路径字符") }
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("https://") { raw = "wss://" + raw.dropFirst(8) } else if raw.hasPrefix("http://") { raw = "ws://" + raw.dropFirst(7) } else if !raw.contains("://") { raw = "ws://" + raw }
        guard !raw.contains("#"), !raw.unicodeScalars.contains(where: { $0.value <= 31 }), var c = URLComponents(string: raw), ["ws","wss"].contains(c.scheme), c.host != nil, c.user == nil, c.password == nil else { throw ClientError.invalidConfiguration }
        c.query = nil; c.fragment = nil
        if channel == .info { c.percentEncodedPath = "/vcpinfo/VCP_Key=" + key }
        else {
            var path = c.percentEncodedPath; while path.hasSuffix("/") { path.removeLast() }
            if !path.contains("/VCPlog") { path += "/VCPlog" }
            if !path.contains("VCP_Key=") { path += "/VCP_Key=" + key }
            c.percentEncodedPath = path; c.queryItems = [URLQueryItem(name: "deviceName",value: "VCPChat-iOS")]
        }
        guard let url = c.url else { throw ClientError.invalidConfiguration }; return url
    }
}
extension JSONValue {
    public func redacting(_ secrets: [String]) -> Self {
        let secrets = secrets.filter { $0.count >= 4 }
        func clean(_ text: String) -> String { secrets.reduce(text) { $0.replacingOccurrences(of: $1,with: "[密钥]") } }
        switch self { case .string(let s): return .string(clean(s)); case .array(let a): return .array(a.map { $0.redacting(secrets) }); case .object(let o): return .object(o.reduce(into: [:]) { $0[clean($1.key)] = $1.value.redacting(secrets) }); default: return self }
    }
}
public enum ActivityUpdate: Sendable { case entries([ActivityEntry]), status(PushChannel,String) }
public actor ActivityHub {
    let sockets: [PushChannel: SessionActor] = [.log: SessionActor(),.info: SessionActor()]
    let store: ChatStore
    var entries: [ActivityEntry] = []
    var tasks: [PushChannel: Task<Void,Never>] = [:]
    var continuation: AsyncStream<ActivityUpdate>.Continuation?
    var publication: Task<Void,Never>?
    var revision = 0
    var sending: Set<String> = []
    var connected: Set<PushChannel> = []
    public init(store: ChatStore) { self.store = store }
    public func updates() async throws -> AsyncStream<ActivityUpdate> {
        entries = try await store.records([ActivityEntry].self,kind: "activities").first ?? []
        for i in entries.indices { entries[i].prepareLogPresentation() }
        let (stream,c) = AsyncStream<ActivityUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8)); continuation = c; c.yield(.entries(entries)); return stream
    }
    public func connect(server: String, key: String, secrets: [String] = []) async {
        await disconnect()
        do { for channel in PushChannel.allCases { _ = try SocketEndpoint.url(server: server,key: key,channel: channel) } }
        catch { for channel in PushChannel.allCases { continuation?.yield(.status(channel,key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未配置" : error.localizedDescription)) }; return }
        for channel in PushChannel.allCases {
            tasks[channel] = Task {
                var delay = 1
                while !Task.isCancelled {
                    continuation?.yield(.status(channel,"正在鉴权"))
                    do {
                        let stream = try await sockets[channel]!.connectPush(configuration: .init(),key: key,channel: channel,server: server)
                        for try await event in stream {
                            try Task.checkCancellation(); if connected.insert(channel).inserted { continuation?.yield(.status(channel,"已连接")) }; delay = 1
                            if event.kind != "connection_ack" { append(ActivityEntry(channel: channel,payload: event.payload.redacting(secrets + [key]))) }
                        }
                    } catch { if Task.isCancelled { return }; continuation?.yield(.status(channel,(error as? ClientError)?.localizedDescription ?? "连接已断开")) }
                    connected.remove(channel)
                    if Task.isCancelled { return }
                    continuation?.yield(.status(channel,"\(delay) 秒后重连"))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }; delay = min(30,delay * 2)
                }
            }
        }
    }
    public func disconnect() async {
        for task in tasks.values { task.cancel() }; tasks = [:]; connected = []
        for (channel,socket) in sockets { await socket.disconnectPush(); continuation?.yield(.status(channel,"未连接")) }
    }
    private func append(_ entry: ActivityEntry) {
        entries.insert(entry,at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        var bytes = 0
        entries = entries.filter { bytes += (try? JSONEncoder().encode($0).count) ?? 0; return bytes <= 8_000_000 }
        changed()
    }
    private func changed() {
        revision += 1
        guard publication == nil else { return }
        publication = Task {
            try? await Task.sleep(for: .milliseconds(50))
            var saved = -1
            while saved != revision {
                let current = revision, snapshot = entries
                do { try await store.put(snapshot,kind: "activities",id: "recent"); saved = current; continuation?.yield(.entries(snapshot)) }
                catch { continuation?.yield(.status(.log,"日志保存失败：\(error.localizedDescription)")); break }
            }
            publication = nil
        }
    }
    public func flush() async { await publication?.value }
    public func markRead() { for i in entries.indices { entries[i].seen = true }; changed() }
    public func clear() {
        entries = entries.filter { $0.data["type"].text == "tool_approval_request" && ["待审批","已发送 · 等待确认"].contains($0.approvalStatus(in: entries)) }; changed()
    }
    public func respond(id: String, approved: Bool, reason: String) async throws {
        guard let entry = entries.first(where: { $0.id == id }), entry.data["type"].text == "tool_approval_request", entry.approvalStatus(in: entries) == "待审批", !entry.requestID.isEmpty else { throw ClientError.server("这条审批已处理或已过期") }
        guard !sending.contains(entry.requestID), connected.contains(.log) else { throw ClientError.server("VCPLog 未连接或这条审批正在发送") }
        let response = try ActivityEntry.response(requestID: entry.requestID,approved: approved,reason: reason)
        sending.insert(entry.requestID); defer { sending.remove(entry.requestID) }
        try await sockets[.log]!.sendPush(response)
        for i in entries.indices where entries[i].requestID == entry.requestID && entries[i].data["type"].text == "tool_approval_request" { entries[i].decision = .init(approved: approved,reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),sentAt: Date().timeIntervalSince1970) }
        changed()
    }
}
