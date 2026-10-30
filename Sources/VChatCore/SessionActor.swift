import Foundation
import Darwin

public actor SessionActor {
    private let network: URLSession
    private var chatTask: Task<Void, Never>?
    private var pacingTask: Task<Void, Never>?
    private var emittedEvents = 0
    private var chatID: UUID?
    private var chatContinuation: AsyncThrowingStream<SessionUpdate, Error>.Continuation?
    private var state: SessionState = .complete
    private var text = "", reasoning = ""
    private var sequence = 0, rawEvents = 0
    private var allParsingOffMain = true
    private var socketTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var socketID: UUID?
    private var socketContinuation: AsyncThrowingStream<PushUpdate, Error>.Continuation?
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        network = URLSession(configuration: configuration)
    }
    public func stream(_ request: ChatRequest) throws -> AsyncThrowingStream<SessionUpdate, Error> {
        guard !request.apiKey.isEmpty else { throw ClientError.missingKey }
        guard !request.configuration.model.isEmpty else { throw ClientError.missingModel }
        let url = try request.configuration.endpoint("v1/chat/completions")
        stop()
        let id = UUID(); chatID = id; text = ""; reasoning = ""; sequence = 0; rawEvents = 0; emittedEvents = 0; allParsingOffMain = true
        let (stream, continuation) = AsyncThrowingStream<SessionUpdate, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        chatContinuation = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.terminate(id) } }
        emit(.connecting)
        chatTask = Task { await self.receiveChat(request, url: url, id: id) }
        let interval = FramePacer(framesPerSecond: request.configuration.framesPerSecond).interval
        pacingTask = Task {
            var deadline = ContinuousClock.now + interval
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                if self.chatID == id && self.state == .streaming && self.rawEvents != self.emittedEvents { self.emit(.streaming) }
                deadline = max(deadline + interval, ContinuousClock.now)
            }
        }
        return stream
    }
    private func terminate(_ id: UUID) { if chatID == id { stop() } }
    public func stop(interrupted: Bool = false) {
        chatTask?.cancel(); chatTask = nil
        pacingTask?.cancel(); pacingTask = nil
        if chatID != nil { emit(interrupted ? .interrupted : .stopped); chatContinuation?.finish() }
        chatID = nil; chatContinuation = nil
    }
    private func emit(_ next: SessionState) {
        state = next; sequence += 1; emittedEvents = rawEvents
        chatContinuation?.yield(SessionUpdate(state: next, text: text, reasoning: reasoning, sequence: sequence, rawEvents: rawEvents, parserWasOffMainThread: allParsingOffMain))
    }
    private func receiveChat(_ request: ChatRequest, url: URL, id: UUID) async {
        do {
            var call = URLRequest(url: url); call.httpMethod = "POST"
            call.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
            call.setValue("application/json", forHTTPHeaderField: "Content-Type")
            call.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            struct Body: Encodable { let model: String; let messages: [ChatTurn]; let stream = true }
            call.httpBody = try JSONEncoder().encode(Body(model: request.configuration.model, messages: request.messages))
            let (bytes, response) = try await network.bytes(for: call)
            guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw ClientError.http(response.statusCode) }
            guard chatID == id else { return }
            emit(.streaming)
            var parser = SSEByteDecoder()
            var done = false
            for try await byte in bytes {
                try Task.checkCancellation(); guard chatID == id else { return }
                if let delta = try parser.byte(byte) {
                    allParsingOffMain = allParsingOffMain && pthread_main_np() == 0
                    rawEvents += 1; text.append(delta.text); reasoning.append(delta.reasoning)
                    guard text.utf8.count + reasoning.utf8.count <= 8_000_000 else { throw ClientError.tooLarge }
                    if delta.done { done = true; break }

                }
            }
            guard chatID == id else { return }
            if !done, let delta = try parser.finish() { text.append(delta.text); reasoning.append(delta.reasoning); done = delta.done }
            guard done else { throw ClientError.interrupted }
            pacingTask?.cancel(); pacingTask = nil
            emit(.complete); chatContinuation?.finish(); chatContinuation = nil; chatID = nil; chatTask = nil
        } catch {
            guard chatID == id else { return }
            pacingTask?.cancel(); pacingTask = nil
            emit(.failed)
            let safe = (error as? ClientError).map { error -> ClientError in
                if case .server(let text) = error { return .server(text.replacingOccurrences(of: request.apiKey, with: "[密钥]")) }; return error
            } ?? (Task.isCancelled ? ClientError.interrupted : ClientError.server("网络连接失败，已收到的内容保留"))
            chatContinuation?.finish(throwing: safe); chatContinuation = nil; chatID = nil; chatTask = nil
        }
    }
    public func models(configuration: ConnectionConfiguration, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }
        var request = URLRequest(url: try configuration.endpoint("v1/models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == 200 else { throw ClientError.http(http.statusCode) }
        struct Catalog: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        return try JSONDecoder().decode(Catalog.self, from: data).data.map(\.id)
    }
    public func connectPush(configuration: ConnectionConfiguration, key: String) throws -> AsyncThrowingStream<PushUpdate, Error> {
        disconnectPush()
        guard !key.isEmpty else { throw ClientError.missingKey }
        // Upstream compares the raw path key (does not percent-decode): reject unsupported path characters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~="))
        guard key.unicodeScalars.allSatisfy(allowed.contains) else { throw ClientError.invalidConfiguration }
        var parts = URLComponents(url: try configuration.endpoint("VCPlog/VCP_Key=\(key)"), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "deviceName", value: "VChatNative-Phase1")]
        let id = UUID(); socketID = id
        let task = network.webSocketTask(with: parts.url!); task.maximumMessageSize = 1_000_000; socket = task
        let (stream, continuation) = AsyncThrowingStream<PushUpdate, Error>.makeStream(bufferingPolicy: .bufferingNewest(100))
        socketContinuation = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.terminateSocket(id) } }
        task.resume()
        socketTask = Task { await self.receivePush(task, id: id) }
        Task { try? await Task.sleep(for: .seconds(10)); self.checkSocketTimeout(id) }
        return stream
    }
    private var acknowledged = false
    private func checkSocketTimeout(_ id: UUID) { if socketID == id && !acknowledged { socketContinuation?.finish(throwing: ClientError.timeout); disconnectPush() } }
    private func terminateSocket(_ id: UUID) { if socketID == id { disconnectPush() } }
    public func disconnectPush() {
        socketID = nil; acknowledged = false
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketTask?.cancel(); socketTask = nil; socketContinuation?.finish(); socketContinuation = nil
    }
    private func receivePush(_ task: URLSessionWebSocketTask, id: UUID) async {
        do {
            while !Task.isCancelled {
                let frame = try await task.receive(); guard socketID == id else { return }
                let data: Data
                switch frame { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw ClientError.invalidResponse }
                guard pthread_main_np() == 0 else { throw ClientError.server("WebSocket 解析隔离失败") }
                struct Event: Decodable { let type: String?; let message: String? }
                let event = try JSONDecoder().decode(Event.self, from: data)
                if event.type == "connection_ack" { acknowledged = true }
                guard acknowledged else { continue }
                socketContinuation?.yield(PushUpdate(connected: true, kind: event.type ?? "event", text: String((event.message ?? String(decoding: data, as: UTF8.self)).prefix(4000))))
            }
        } catch {
            guard socketID == id else { return }
            socketContinuation?.finish(throwing: acknowledged ? ClientError.server("WebSocket 已断开，请重新连接") : ClientError.authentication); disconnectPush()
        }
    }
}
