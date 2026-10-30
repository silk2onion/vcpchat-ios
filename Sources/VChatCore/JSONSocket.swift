import Foundation
/// Delegate is immutable; redirects are refused for credential-bearing service requests.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor JSONSocket {
    private let network: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiving: Task<Void,Never>?
    private var heartbeat: Task<Void,Never>?
    private var continuation: AsyncThrowingStream<JSONValue,Error>.Continuation?
    private var generation: UUID?
    public init() { let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 30; network = URLSession(configuration: config,delegate: NoRedirectDelegate(),delegateQueue: nil) }
    public func connect(_ url: URL,maximumBytes: Int = 30_000_000) -> AsyncThrowingStream<JSONValue,Error> {
        close(); let id = UUID(); generation = id
        let task = network.webSocketTask(with: url); task.maximumMessageSize = maximumBytes; socket = task
        let (stream,c) = AsyncThrowingStream<JSONValue,Error>.makeStream(bufferingPolicy: .bufferingOldest(128)); continuation = c
        c.onTermination = { [weak self] _ in Task { await self?.terminate(id) } }
        task.resume()
        receiving = Task {
            do { while !Task.isCancelled {
                let frame = try await task.receive(); guard generation == id else { return }
                let data: Data; switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw ClientError.invalidResponse }
                guard data.count <= maximumBytes else { throw ClientError.server("WebSocket 请求过大，未执行") }
                let value = try JSONDecoder().decode(JSONValue.self,from: data)
                if case .dropped = c.yield(value) { throw ClientError.server("请求队列已满，连接已暂停，请重新连接") }
            } } catch { if generation == id { c.finish(throwing: (error as? ClientError) ?? ClientError.server("WebSocket 连接已断开")); close() } }
        }
        heartbeat = Task { while !Task.isCancelled { do { try await Task.sleep(for: .seconds(20)); try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void,Error>) in task.sendPing { error in if let error { c.resume(throwing: error) } else { c.resume() } } } } catch { if generation == id { continuation?.finish(throwing: ClientError.interrupted); close() }; return } } }
        return stream
    }
    private func terminate(_ id: UUID) { if generation == id { close() } }
    public func send(_ value: JSONValue) async throws {
        guard let task = socket, let id = generation else { throw ClientError.server("连接尚未建立") }
        let data = try JSONEncoder().encode(value); try await task.send(.string(String(decoding: data,as: UTF8.self)))
        guard generation == id else { throw CancellationError() }
    }
    public func close() {
        generation = nil; receiving?.cancel(); receiving = nil; heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway,reason: nil); socket = nil; continuation?.finish(); continuation = nil
    }
}
