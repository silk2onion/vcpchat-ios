#if os(iOS)
import Foundation
import UIKit
import VChatCore

/// Keep the same live data task across scene changes. A background upload task
/// buffers the response body and cannot be used for incremental SSE presentation.
@MainActor final class BackgroundReplyTransfers: NSObject, @preconcurrency URLSessionDataDelegate, @preconcurrency URLSessionDownloadDelegate {
    static let identifier = "vchat.background-replies.v1"
    private let backgroundIdentifier: String
    private let reconnectLegacy: Bool
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration? = nil, backgroundIdentifier: String = BackgroundReplyTransfers.identifier) {
        self.backgroundIdentifier = backgroundIdentifier
        reconnectLegacy = configuration == nil
        self.configuration = configuration ?? .ephemeral
        self.configuration.timeoutIntervalForRequest = 600
        self.configuration.timeoutIntervalForResource = 600
        self.configuration.shouldUseExtendedBackgroundIdleMode = true
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCache = nil
        super.init()
    }
    private static func backgroundConfiguration(_ identifier: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        return config
    }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

    // Reattach any earlier system-managed jobs without resubmitting their requests.
    private lazy var legacySession = URLSession(configuration: Self.backgroundConfiguration(backgroundIdentifier), delegate: self, delegateQueue: .main)
    struct Receipt: Codable, Sendable {
        var error: String?
        var stopped = false
    }
    enum Event: Sendable { case bytesAvailable, finished(Receipt) }
    struct Ticket {
        let directory: URL
        let events: AsyncStream<Event>
        fileprivate let output: AsyncStream<Event>.Continuation
    }
    func refreshProgress() {
        for client in remote.values { client.retryDownloadOnReturn() }
        for (id,ticket) in tickets where !delivered.contains(id) { ticket.output.yield(.bytesAvailable) }
    }
    var vault: CredentialVault?
    private var remote: [String:ServerReplyClient] = [:]
    private var downloads: [String:URLSessionTask] = [:]
    private var importing = 0
    private var tickets: [String: Ticket] = [:]
    private var tasks: [String: URLSessionTask] = [:]
    private var delivered = Set<String>()
    private var completion: (() -> Void)?
    private var finishedEvents = false
    private var root: URL?
    private var configuring = false
    private var missingAtWake = Set<String>()

    func handleWake(_ completion: @escaping () -> Void) {
        self.completion = completion
        if root != nil && reconnectLegacy { _ = legacySession }
        finishWakeIfReady()
    }
    func abandonWake() {
        let handler = completion; completion = nil; finishedEvents = false
        handler?()
    }
    private func finishWakeIfReady() {
        guard !configuring, importing == 0, finishedEvents, delivered.isEmpty, let completion else { return }
        finishedEvents = false; self.completion = nil; completion()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // A completed transfer may no longer appear in allTasks while its delegate
        // events are still queued. Only classify missing tasks after those events drain.
        for id in missingAtWake { deliver(Receipt(error: "后台请求已中断，可在原消息上重新生成"), for: id) }
        missingAtWake.removeAll()
        finishedEvents = true
        finishWakeIfReady()
    }
    func configure(at directory: URL, jobs: [BackgroundReplyJob]) async throws -> [String: Ticket] {
        configuring = true
        defer { configuring = false; finishWakeIfReady() }
        var root = directory.appendingPathComponent("ReplyTransfers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let ids = Set(jobs.map(\.id))
        for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !ids.contains(item.lastPathComponent) {
            if FileManager.default.fileExists(atPath:item.appendingPathComponent(ServerReplyClient.marker).path), let vault,
               !(await vault.remove([ServerReplyClient.account(item.lastPathComponent)])).isEmpty { continue }
            try? FileManager.default.removeItem(at: item)
        }
        self.root = root
        for id in ids {
            let ticket=makeTicket(id, root:root)
            if FileManager.default.fileExists(atPath:ticket.directory.appendingPathComponent(ServerReplyClient.marker).path),
               let vault { remote[id]=serverClient(id, ticket:ticket, vault:vault) }
        }
        ServerReplyClient.trace("configure jobs=\(jobs.count) marked=\(remote.count)")
        let restored = tickets
        let running = (!reconnectLegacy || (jobs.isEmpty && completion == nil)) ? [] : await legacySession.allTasks
        for task in running {
            if let tag=task.taskDescription, tag.hasPrefix(ServerReplyClient.taskPrefix) {
                let id=String(tag.dropFirst(ServerReplyClient.taskPrefix.count))
                if remote[id] != nil && downloads[id] == nil { downloads[id]=task } else { task.cancel() }
                continue
            }
            guard let id = task.taskDescription, ids.contains(id) else { task.cancel(); continue }
            guard task.state != .suspended else { task.cancel(); continue }
            tasks[id] = task
        }
        for (id, ticket) in restored {
            if let data = try? Data(contentsOf: ticket.directory.appendingPathComponent("receipt")),
               let receipt = try? JSONDecoder().decode(Receipt.self, from: data) {
                deliver(receipt, for: id)
            } else if let client=remote[id] {
                client.start(downloadExists:downloads[id] != nil)
            } else if tasks[id] == nil {
                if completion != nil && !finishedEvents { missingAtWake.insert(id) }
                else { deliver(Receipt(error: "后台请求已中断，可在原消息上重新生成"), for: id) }
            }
        }
        refreshProgress()
        return restored
    }
    private func makeTicket(_ id: String, root: URL) -> Ticket {
        let (events, output) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let ticket = Ticket(directory: root.appendingPathComponent(id, isDirectory: true), events: events, output: output)
        tickets[id] = ticket
        return ticket
    }
    nonisolated private static func prepareDirectory(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }
    private func serverClient(_ id: String,ticket: Ticket,vault: CredentialVault) -> ServerReplyClient {
        ServerReplyClient(id:id,directory:ticket.directory,vault:vault,changed:{ ticket.output.yield(.bytesAvailable) },
            scheduleDownload:{ [weak self] req in
                guard let self, self.downloads[id] == nil else { return }
                var call=req; call.timeoutInterval=600
                let task=self.legacySession.downloadTask(with:call)
                task.taskDescription=ServerReplyClient.taskPrefix + id; self.downloads[id]=task; task.resume()
            },finish:{ [weak self] receipt in self?.deliver(receipt,for:id) })
    }

    func submit(_ job: BackgroundReplyJob, request: ChatRequest, locationText: ChatRequest.LocationText? = nil, room: ChatRoom, store: ChatStore) async throws -> Ticket {
        guard let root else { throw ClientError.server("后台收回复尚未就绪，请重新打开 App") }
        try await store.registerBackgroundReply(job)
        let ticket = makeTicket(job.id, root: root)
        room.backgroundJobID = job.id
        do {
            try await Self.prepareDirectory(ticket.directory)
            let makeRequest: @Sendable () async throws -> URLRequest = {
                try await request.urlRequest(streaming: true, locationText: locationText)
            }
            if room.cancelled {
                cancel(job.id)
                return ticket
            }
            if room.serverOwnsReply {
                guard let vault else { throw ClientError.server("续传凭据尚未就绪") }
                let client=serverClient(job.id,ticket:ticket,vault:vault)
                try await client.prepare(request)
                if room.cancelled { client.close(); cancel(job.id); return ticket } // no PUT was issued
                remote[job.id]=client
                client.start(initial:makeRequest,route:request.configuration.endpointMode == .vcpTools ? "chatvcp" : "chat")
                return ticket
            }
            let call = try await makeRequest()
            if room.cancelled { cancel(job.id); return ticket }
            let task = session.dataTask(with: call)
            task.prefersIncrementalDelivery = true
            task.taskDescription = job.id; tasks[job.id] = task
            task.resume()
        } catch {
            deliver(Receipt(error: error.localizedDescription), for: job.id)
        }
        return ticket
    }
    func cancel(_ id: String) {
        if let client=remote[id] { client.stop(); return }
        tasks[id]?.cancel()
        deliver(Receipt(stopped: true), for: id)
    }

    // Response bytes can arrive in several callbacks, even across a process relaunch.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription, let ticket = tickets[id], !delivered.contains(id) else { return }
        if let http = dataTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
        do {
            let url = ticket.directory.appendingPathComponent("response")
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            let length = try file.seekToEnd()
            guard length + UInt64(data.count) <= 64 * 1024 * 1024 else { throw ClientError.tooLarge }
            try file.write(contentsOf: data)
            ticket.output.yield(.bytesAvailable)
        } catch {
            dataTask.cancel()
            deliver(Receipt(error: error.localizedDescription), for: id)
        }
    }
    // Background download completion can wake a suspended / system-terminated app.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag=downloadTask.taskDescription, tag.hasPrefix(ServerReplyClient.taskPrefix) else { return }
        let id=String(tag.dropFirst(ServerReplyClient.taskPrefix.count))
        guard let client=remote[id], let ticket=tickets[id], !delivered.contains(id) else { return }
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { client.downloadFailed(); return }
        do {
            let dest=ticket.directory.appendingPathComponent(ServerReplyClient.archiveName)
            if FileManager.default.fileExists(atPath:dest.path) { try FileManager.default.removeItem(at:dest) }
            try FileManager.default.moveItem(at:location,to:dest)
            importing += 1
            Task { await client.acceptArchive(); importing -= 1; finishWakeIfReady() }
        } catch { client.downloadFailed() }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        if id.hasPrefix(ServerReplyClient.taskPrefix) {
            let job=String(id.dropFirst(ServerReplyClient.taskPrefix.count))
            if downloads[job]?.taskIdentifier == task.taskIdentifier { downloads[job]=nil }
            if error != nil && downloads[job] == nil { remote[job]?.downloadFailed() }
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let message: String?
        if error != nil { message = "后台请求未完成，请检查网络后重试" }
        else if let status, !(200..<300).contains(status) { message = ClientError.http(status).localizedDescription }
        else if status == nil { message = ClientError.invalidResponse.localizedDescription }
        else { message = nil }
        deliver(Receipt(error: message), for: id)
    }
    private func deliver(_ receipt: Receipt, for id: String) {
        guard let ticket = tickets[id], delivered.insert(id).inserted else { return }
        // Keep a receipt until the SQLite transaction commits. Relaunch can replay that commit, never the POST.
        try? JSONEncoder().encode(receipt).write(to: ticket.directory.appendingPathComponent("receipt"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ticket.output.yield(.finished(receipt)); ticket.output.finish()
    }
    func acknowledge(_ id: String, committed: Bool) {
        downloads.removeValue(forKey:id)?.cancel()
        remote.removeValue(forKey:id)?.close()
        if let ticket=tickets.removeValue(forKey:id), committed {
            if let vault, FileManager.default.fileExists(atPath:ticket.directory.appendingPathComponent(ServerReplyClient.marker).path) {
                Task {
                    if (await vault.remove([ServerReplyClient.account(id)])).isEmpty { try? FileManager.default.removeItem(at:ticket.directory) }
                }
            } else { try? FileManager.default.removeItem(at:ticket.directory) }
        }
        tasks[id] = nil; delivered.remove(id)
        finishWakeIfReady()
    }
}

// The response spool is also the relaunch checkpoint. A new reader replays it
// once; the running reader consumes only new bytes, including across scene changes.
private actor ReplyStreamReader {
    private let file: URL
    private var offset: UInt64 = 0
    private var parser = SSEByteDecoder()
    private var json: Bool?
    private var text = "", reasoning = ""
    private var byteCount = 0
    private var done = false
    private var invalid = false
    init(_ directory: URL) { file = directory.appendingPathComponent("response") }
    var snapshot: FinishedReply? { byteCount > 0 || done ? .init(text: text, reasoning: reasoning) : nil }
    private func append(_ delta: TokenDelta) throws {
        let size = delta.text.utf8.count + delta.reasoning.utf8.count
        guard size <= 8_000_000 - byteCount else { throw ClientError.tooLarge }
        byteCount += size
        text += delta.text; reasoning += delta.reasoning; done = delta.done
    }
    func read(final: Bool) throws -> FinishedReply? {
        guard !invalid else { throw ClientError.invalidResponse }
        do { return try consume(final: final) }
        catch { invalid = true; throw error }
    }
    private func consume(final: Bool) throws -> FinishedReply? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            if final { throw ClientError.invalidResponse }; return nil
        }
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        try input.seek(toOffset: offset)
        while !done, json != true, let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            offset += UInt64(data.count)
            if json == nil {
                guard let first = data.first(where: { ![9,10,13,32].contains($0) }) else { continue }
                json = first == 123 // a legacy request or an endpoint that ignores stream:true
                if json == true { break }
            }
            for byte in data {
                if let delta = try parser.byte(byte) { try append(delta); if done { break } }
            }
        }
        if final {
            if json == true { return try FinishedReply(data: Data(contentsOf: file, options: .mappedIfSafe)) }
            if !done, let last = try parser.finish() { try append(last) }
            guard done else { throw ClientError.interrupted }
        }
        return snapshot
    }
}

extension ChatViewModel {
    func restoreBackgroundReplies(store: ChatStore, root: URL) async throws {
        replyTransfers.vault = vault
        let jobs = try await store.backgroundReplies()
        let tickets = try await replyTransfers.configure(at: root, jobs: jobs)
        await ReplyPresentation.dismissOrphanedActivities(activeIDs: Set(jobs.map(\.id)))
        for job in jobs {
            guard let ticket = tickets[job.id] else { continue }
            let room: ChatRoom
            if let existing = rooms[job.topicID] { room = existing }
            else {
                room = ChatRoom(id: job.topicID, messages: try await store.messages(topicID: job.topicID))
                let draft = try await store.records(TopicDraft.self, kind: "draft").first { $0.id == room.id }
                room.draft = draft?.text ?? ""; room.attachments = draft?.attachments ?? []
                rooms[room.id] = room
            }
            room.serverOwnsReply = FileManager.default.fileExists(atPath:ticket.directory.appendingPathComponent(ServerReplyClient.marker).path)
            room.busy = true; room.receivesInBackground = true; room.backgroundJobID = job.id
            room.connection = "正在接收回复"
            room.generation = Task {
                await collectBackgroundReply(job, ticket: ticket, room: room, store: store)
                room.busy = false; room.generation = nil
            }
        }
    }
    func collectBackgroundReply(_ job: BackgroundReplyJob, ticket: BackgroundReplyTransfers.Ticket, room: ChatRoom, store: ChatStore) async {
        var committed = false
        defer {
            room.backgroundJobID = nil; room.receivedReplyBytes = 0
            replyTransfers.acknowledge(job.id, committed: committed)
        }
        let reader = ReplyStreamReader(ticket.directory)
        let message = room.messages.first { $0.id == job.messageID }
        let prefix = message?.text ?? "", reasoningPrefix = message?.reasoning ?? ""
        var nextBackgroundUpdate: ContinuousClock.Instant?
        for await event in ticket.events {
            switch event {
            case .bytesAvailable:
                guard !room.cancelled else { continue }
                if let live = try? await reader.read(final: false), !room.cancelled {
                    message?.text = prefix + live.text; message?.reasoning = reasoningPrefix + live.reasoning
                    message?.status = "streaming"; room.connection = "正在回复"; room.frames += 1
                    let bytes = live.text.utf8.count + live.reasoning.utf8.count
                    room.receivedReplyBytes = bytes
                    let now = ContinuousClock.now
                    if backgrounded, nextBackgroundUpdate.map({ now >= $0 }) ?? true {
                        nextBackgroundUpdate = now + .seconds(2)
                        await updateReplyActivity(job.id, bytes)
                    } else if !backgrounded { nextBackgroundUpdate = nil }
                    // Only the newest signal matters; the spool retains every chunk.
                    try? await Task.sleep(for: .milliseconds(backgrounded ? 100 : 16))
                }
            case .finished(let receipt):
                var issue = receipt.error
                var reply: FinishedReply?
                do { reply = try await reader.read(final: !receipt.stopped && issue == nil) }
                catch {
                    reply = await reader.snapshot
                    if issue == nil { issue = error is ClientError ? "回复传输未完整结束" : "未收到完整的 AI 回复" }
                }
                let stopped = receipt.stopped || room.cancellation == .stopped
                do {
                    let record: StoredMessage?
                    do { record = try await store.finishBackgroundReply(job, reply: reply, stopped: stopped, interrupted: issue != nil) }
                    catch ClientError.tooLarge {
                        issue = ClientError.tooLarge.localizedDescription
                        record = try await store.finishBackgroundReply(job, reply: nil)
                    }
                    ServerReplyClient.trace("commit length=\(record?.content.utf8.count ?? -1) status=\(record?.status ?? "missing")")
                    committed = true
                    guard let record else { return }
                    if let message = room.messages.first(where: { $0.id == record.id }) {
                        message.text = record.content; message.reasoning = record.reasoning; message.status = record.status
                    }
                    if record.status == "complete" {
                        if let id = job.userID { room.messages.first { $0.id == id }?.status = "complete" }
                        room.connection = "回复完成"
                        await ReplyPresentation.end(job.id, phase: .complete)
                        await ReplyPresentation.notify(job)
                    } else {
                        room.connection = stopped ? "已停止" : "已中断"
                        room.error = issue
                        await ReplyPresentation.end(job.id, phase: stopped ? .stopped : .interrupted)
                    }
                    room.pendingCount = room.messages.filter { $0.status == "pending" }.count
                } catch {
                    room.error = "本机保存失败：" + error.localizedDescription
                    await ReplyPresentation.end(job.id, phase: .interrupted)
                }
                return
            }
        }
    }
}
#endif
