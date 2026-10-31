import SwiftUI
import VChatCore
import VChatRendering

struct DataManagementView: View {
    let model: ChatViewModel
    @State private var archives: [HistoryArchive] = []
    @State private var clearing = false
    @State private var forgetting = false
    @State private var restoring: HistoryArchive?
    @State private var working = false
    @State private var error: String?
    @State private var notice = ""
    private var unavailable: Bool { working || model.synchronizing || model.savingConnection || model.unlockingCredentials || model.rooms.values.contains(where: \.busy) }
    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if !notice.isEmpty { Section { Text(notice).foregroundStyle(.secondary) } }
            Section("聊天记录") {
                Button("备份并清空聊天记录",systemImage: "archivebox",role: .destructive) { clearing = true }.disabled(unavailable)
                Text("先在本机保留恢复备份，再清空话题、消息和草稿。保留联系人、群组、设置、笔记和文件；不会删除桌面内容。").font(.caption).foregroundStyle(.secondary)
            }
            Section("连接密钥") {
                Button("移除所有连接密钥",systemImage: "key.slash",role: .destructive) { forgetting = true }.disabled(unavailable)
                Text("断开日志和文件节点，停止朗读，并移除聊天、日志、同步、日记、文件与语音密钥。保留服务地址和本机数据。").font(.caption).foregroundStyle(.secondary)
            }
            Section("聊天备份") {
                if archives.isEmpty { Text("清空聊天前会自动创建备份").foregroundStyle(.secondary) }
                ForEach(archives) { archive in
                    VStack(alignment: .leading,spacing: 8) {
                        Text(Date(timeIntervalSince1970: archive.createdAt),format: .dateTime.year().month().day().hour().minute())
                        Text("\(archive.topicCount) 个话题 · \(archive.messageCount) 条消息").font(.caption).foregroundStyle(.secondary)
                        if archive.restoredAt != nil { Label("已恢复为独立副本",systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
                        else { Button("恢复为独立副本",systemImage: "arrow.uturn.backward") { restoring = archive }.disabled(unavailable) }
                    }.padding(.vertical,4)
                }
            }
            if working { ProgressView("正在处理本机数据…") }
        }.formStyle(.grouped).scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("数据与连接")
        .task { await refresh() }
        .confirmationDialog("先保留完整备份，再清空聊天记录？",isPresented: $clearing,titleVisibility: .visible) {
            Button("备份并清空",role: .destructive) { work { try await model.clearHistory(); notice = "已保存本机备份，聊天记录已清空" } }
        }
        .confirmationDialog("移除所有连接密钥？下次连接需重新填写。",isPresented: $forgetting,titleVisibility: .visible) {
            Button("断开连接并移除密钥",role: .destructive) { work { try await model.forgetCredentials(); notice = "所有连接密钥已移除" } }
        }
        .confirmationDialog("恢复为新的联系人、群组和话题副本？不覆盖当前内容，不写回桌面。",isPresented: Binding(get: { restoring != nil },set: { if !$0 { restoring = nil } }),titleVisibility: .visible) {
            Button("恢复副本") { if let archive = restoring { work { try await model.restoreHistory(archive.id); notice = "聊天、草稿和已删除消息已恢复为独立副本；当前内容未改动" } }; restoring = nil }
        }
    }
    private func refresh() async { do { archives = try await model.store?.historyArchives() ?? [] } catch { self.error = error.localizedDescription } }
    private func work(_ action: @escaping @MainActor () async throws -> Void) {
        guard !unavailable else { return }; working = true; error = nil; notice = ""
        Task { defer { working = false }; do { try await action(); await refresh() } catch { self.error = error.localizedDescription; await refresh() } }
    }
}
extension ChatViewModel {
    func clearHistory() async throws {
        guard !synchronizing,!rooms.values.contains(where: \.busy),let store,let owner = mainAgent else { throw ClientError.server("请先停止生成并等待同步结束") }
        synchronizing = true; defer { synchronizing = false }
        // A cancelled debounce may already be saving: await it before the atomic archive.
        for room in Array(rooms.values) {
            room.draftSave?.cancel(); await room.draftSave?.value
            try await store.put(TopicDraft(id: room.id,text: room.draft,attachments: room.attachments),kind: "draft",id: room.id)
        }
        let topic = ChatTopic(ownerId: owner.id)
        try await store.clearHistory(replacement: topic)
        rooms = [:]; topics = [topic]; results = []; search = ""; await openTopic(topic)
    }
    func restoreHistory(_ id: String) async throws {
        guard !synchronizing,!rooms.values.contains(where: \.busy),let store else { throw ClientError.server("请先停止生成并等待同步结束") }
        synchronizing = true; defer { synchronizing = false }
        let restored = try await store.restoreHistoryCopy(id)
        agents = try await store.records(VCPAgent.self,kind: "agent"); groups = try await store.records(VCPGroup.self,kind: "group"); topics = try await store.records(ChatTopic.self,kind: "topic")
        if let topic = restored.first { await flushDraft(); await openTopic(topic) }
    }
    func forgetCredentials() async throws {
        guard !synchronizing,!rooms.values.contains(where: \.busy),!savingConnection,!unlockingCredentials else { throw ClientError.server("请先停止生成并等待连接操作完成") }
        synchronizing = true; defer { synchronizing = false }
        speech.stop(); await activity.disconnect(); await fileNode.stop()
        apiKey = ""; logKey = ""; serviceSecrets = [:]
        let failures = await vault.remove(["chat-api-key","vcp-log-key"] + ServiceSecret.allCases.map(\.rawValue))
        credentialsLocked = !failures.isEmpty
        if failures.isEmpty { UserDefaults.standard.removeObject(forKey: "native.secrets-exist") }
        else { throw ClientError.server("内存中的密钥已移除，但有 \(failures.count) 项未能从钥匙串移除。请允许系统确认后重试。") }
    }
}
