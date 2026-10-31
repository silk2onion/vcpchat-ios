import Foundation
import Observation
import VChatCore
@MainActor @Observable final class ActivityCenter {
    var entries: [ActivityEntry] = []
    var statuses: [PushChannel: String] = [.log: "未连接",.info: "未连接"]
    var error: String?
    var enabled = false
    var now = Date().timeIntervalSince1970
    @ObservationIgnored private var expiry: Task<Void,Never>?
    @ObservationIgnored private var hub: ActivityHub?
    @ObservationIgnored private var task: Task<Void,Never>?
    var unread: Int { entries.filter { !$0.seen }.count }
    var pending: [ActivityEntry] {
        var ids: Set<String> = []
        return entries.filter { $0.data["type"].text == "tool_approval_request" && !$0.requestID.isEmpty && $0.approvalStatus(in: entries,now: now) == "待审批" && ids.insert($0.requestID).inserted }
    }
    func load(store: ChatStore) async {
        guard hub == nil else { return }; startClock(); let hub = ActivityHub(store: store); self.hub = hub
        do { let stream = try await hub.updates(); task = Task { for await update in stream { if Task.isCancelled { return }; switch update { case .entries(let value): entries = value; case .status(let channel,let value): statuses[channel] = value } } } }
        catch { self.error = error.localizedDescription }
    }
    func connect(server: String,key: String,secrets: [String]) async { enabled = true; startClock(); await hub?.connect(server: server,key: key,secrets: secrets) }
    func pause() async { expiry?.cancel(); expiry = nil; await hub?.disconnect(); await hub?.flush() }
    func disconnect() async { enabled = false; await hub?.disconnect() }
    func markRead() async { await hub?.markRead() }
    private func startClock() { guard expiry == nil else { return }; expiry = Task { while !Task.isCancelled { now = Date().timeIntervalSince1970; do { try await Task.sleep(for: .seconds(1)) } catch { return } } } }
    func clear() async { await hub?.clear() }
    func respond(_ entry: ActivityEntry,approved: Bool,reason: String) async throws { guard let hub else { throw ClientError.server("本机日志尚未就绪") }; try await hub.respond(id: entry.id,approved: approved,reason: reason) }
}
