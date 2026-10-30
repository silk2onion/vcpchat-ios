import Foundation
public struct MobileSyncSettings: Codable, Sendable, Equatable {
    public var httpURL = ""; public var socketURL = ""; public init() {}
    public static func endpoint(_ raw: String) throws -> URL {
        let base = try ConnectionConfiguration(server: raw).baseURL(); guard let c = URLComponents(url: base,resolvingAgainstBaseURL: false),c.query == nil,c.fragment == nil else { throw SyncWire.fail("同步 HTTP 地址不能带查询参数") }
        var s = c; var path = s.path; while path.hasSuffix("/") { path.removeLast() }; if path.hasSuffix("/api/mobile-sync") { path.removeLast("/api/mobile-sync".count) }; s.path = path + "/api/mobile-sync"; return s.url!
    }
    public static func socket(_ raw: String,token: String) throws -> URL {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),["ws","wss"].contains(c.scheme),c.host != nil,c.user == nil,c.password == nil,c.fragment == nil,["","/","/ws-sync"].contains(c.path) else { throw SyncWire.fail("同步通道请填写 ws(s)://桌面地址:5975/ 或 /ws-sync") }
        var q = c.queryItems ?? []; q.removeAll { $0.name == "token" }; q.append(URLQueryItem(name: "token",value: token)); c.queryItems = q
        // A literal plus in a token must not become a form-urlencoded space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B"); guard let url = c.url else { throw ClientError.invalidConfiguration }; return url
    }
}
actor SyncChannel {
    private let socket = JSONSocket(); private var reader: Task<Void,Never>?; private var deadline: Task<Void,Never>?
    private var pending: (UUID,String,CheckedContinuation<JSONValue,Error>)?
    private var failure: (any Error)?
    func open(_ url: URL) async {
        let stream = await socket.connect(url,strictJSON: true)
        reader = Task { do { for try await value in stream { receive(value) }; fail(ClientError.interrupted) } catch { fail(error) } }
    }
    private func receive(_ value: JSONValue) {
        if value["type"].text == "SYNC_ERROR" { fail(SyncWire.fail(Self.error(value["error"]))); return }
        guard let (id,type,c) = pending,type == value["type"].text else { return }; pending = nil; deadline?.cancel(); deadline = nil; _ = id; c.resume(returning: value)
    }
    static func error(_ value: JSONValue) -> String { if case .string(let v) = value { return v }; let text = [value["code"].text,value["message"].text].filter { !$0.isEmpty }.joined(separator: "："); return text.isEmpty ? "同步服务返回错误" : text }
    private func fail(_ error: any Error) { failure = error; if let (_,_,c) = pending { pending = nil; c.resume(throwing: error) }; deadline?.cancel(); deadline = nil }
    func send(_ value: JSONValue) async throws { try Task.checkCancellation(); if let failure { throw failure }; try await socket.send(value) }
    func request(_ value: JSONValue,expected: String) async throws -> JSONValue {
        try Task.checkCancellation(); if let failure { throw failure }; guard pending == nil else { throw SyncWire.fail("同步请求尚未完成") }; let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                pending = (id,expected,c)
                deadline = Task { do { try await Task.sleep(for: .seconds(60)); if pending?.0 == id { fail(ClientError.timeout); await socket.close() } } catch {} }
                Task { do { try await send(value) } catch { if pending?.0 == id { fail(error) } } }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) async { if pending?.0 == id { fail(CancellationError()); await socket.close() } }
    func close() async { fail(CancellationError()); reader?.cancel(); reader = nil; await socket.close() }
}
struct SyncHTTP: Sendable {
    let endpoint: URL; let token: String; private let network = VCPHTTP(allowingRedirects: false)
    init(endpoint: URL,token: String) { self.endpoint = endpoint; self.token = token }
    private func response(_ path: String,body: Data?,mime: String,method: String = "POST") async throws -> HTTPDataReply {
        try Task.checkCancellation(); guard let url = URL(string: endpoint.absoluteString + path) else { throw ClientError.invalidConfiguration }
        let result = try await network.response(url,method: method,headers: ["Authorization":"Bearer " + token,"Content-Type":mime,"X-Idempotency-Key":UUID().uuidString],body: body,limit: 30_000_000)
        guard (200..<300).contains(result.status) else { throw ClientError.http(result.status) }; return result
    }
    func json(_ path: String,_ body: JSONValue) async throws -> JSONValue { try StrictJSON.decode(await response(path,body: JSONEncoder().encode(body),mime: "application/json").data) }
    func ndjson(_ path: String,_ body: JSONValue) async throws -> [JSONValue] { try await ndjson(path,data: JSONEncoder().encode(body),mime: "application/json") }
    func ndjson(_ path: String,data: Data,mime: String = "application/x-ndjson") async throws -> [JSONValue] {
        let reply = try await response(path,body: data,mime: mime).data
        guard reply.isEmpty || reply.last == 10 else { throw SyncWire.fail("同步 NDJSON 被截断，未写入本机") }
        return try reply.split(separator: 10).filter { !$0.allSatisfy { [9,13,32].contains($0) } }.map { bytes in let value = try StrictJSON.decode(Data(bytes)); guard value["ok"].bool == true else { throw SyncWire.fail(SyncChannel.error(value["error"])) }; return value }
    }
    func binary(_ path: String,data: Data? = nil,mime: String = "application/octet-stream") async throws -> HTTPDataReply { let reply = try await response(path,body: data,mime: mime,method: data == nil ? "GET" : "POST"); guard reply.data.count <= 20_000_000 else { throw ClientError.tooLarge }; return reply }
}
