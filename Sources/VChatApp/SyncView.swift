import SwiftUI
import VChatCore
import VChatRendering
struct SyncView: View {
    @Bindable var model: ChatViewModel
    @State private var profiles: [SyncProfile] = []
    @State private var checkpoints: [SyncCheckpoint] = []
    @State private var progress = ""
    @State private var error: String?
    @State private var task: Task<Void,Never>?
    @State private var confirmWrite = false
    @State private var restoring: SyncCheckpoint?
    @Environment(\.scenePhase) private var phase
    private let engine = MobileSync()
    private var selected: SyncProfile? { guard let endpoint = try? MobileSyncSettings.endpoint(model.services.sync.httpURL).absoluteString else { return nil }; return profiles.first { $0.endpoint == endpoint } }
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                Text("与 VCPChat 的 MobileSync 配对。现有本机会话保留，同步内容使用独立来源身份。").font(.system(size: 14)).foregroundStyle(palette.muted)
                VStack(alignment: .leading,spacing: 24) {
                    WorkspaceField(title: "桌面 HTTP 地址",palette: palette) { TextField("http://桌面:5974",text: $model.services.sync.httpURL).autocorrectionDisabled().accessibilityLabel("同步 HTTP 地址") }
                    WorkspaceField(title: "同步 WebSocket 地址",palette: palette) { TextField("ws://桌面:5975/",text: $model.services.sync.socketURL).autocorrectionDisabled().accessibilityLabel("同步 WebSocket 地址") }
                    WorkspaceField(title: "Mobile Sync Token",palette: palette) { SecureField("桌面同步 Token",text: Binding(get: { model.serviceSecrets[.syncToken] ?? "" },set: { model.serviceSecrets[.syncToken] = $0 })) }
                    if model.credentialsLocked { Label("连接尚未解锁，请先在服务器设置中主动解锁",systemImage: "lock").font(.caption); NavigationLink("打开连接设置") { ConnectionView(model: model,embedded: true) } }
                }.padding(18).workspaceGlass(palette).disabled(model.synchronizing)
                VStack(spacing: 12) {
                    Button("只拉取桌面内容",systemImage: "arrow.down") { start(.pull) }.workspaceAction(palette,primary: true).disabled(unavailable)
                    Button("双向同步",systemImage: "arrow.up.arrow.down") { confirmWrite = true }.workspaceAction(palette).disabled(unavailable)
                    if model.synchronizing { HStack { ProgressView().controlSize(.small); Text(progress) }; Button("取消同步",role: .cancel) { task?.cancel() } }
                    else if !progress.isEmpty { Label(progress,systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(palette.muted) }
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Text("头像单独传输；历史附件只同步身份与提取内容，原文件需要在文件页导入。桌面须启用 VCPMobileSync（Wire 1.5）。同步在前台运行。").font(.system(size: 13)).foregroundStyle(palette.muted)
                if let selected,selected.lastSync > 0 { LabeledContent("上次完成",value: Date(timeIntervalSince1970: selected.lastSync/1000).formatted(date: .abbreviated,time: .shortened)); Text("\(selected.entities.values.filter { $0.identity.entityType == "owner" && $0.identity.ownerType == "agent" && $0.deletedAt == nil }.count) 位 Agent · \(selected.entities.values.filter { $0.identity.entityType == "topic" && $0.deletedAt == nil }.count) 个话题").font(.caption).foregroundStyle(palette.muted) }
                VStack(alignment: .leading,spacing: 16) {
                    Text("本机恢复点").font(.system(size: 16,weight: .semibold))
                    if matching.isEmpty { Text("首次同步完成后会保存原状与结果；恢复仅影响此同步来源。").font(.system(size: 13)).foregroundStyle(palette.muted) }
                    ForEach(matching) { point in HStack { VStack(alignment: .leading,spacing: 4) { Text(Date(timeIntervalSince1970: point.at),format: .dateTime.month().day().hour().minute().second()); Text("同步前 \(point.before.topics.count) 个话题 · 同步后 \(point.after.topics.count) 个话题").font(.caption).foregroundStyle(palette.muted) }; Spacer(); Button("恢复此前状态") { restoring = point }.disabled(model.synchronizing) } }
                }.padding(18).workspaceGlass(palette)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.buttonStyle(WorkspacePress()).navigationTitle("桌面同步").background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
            .task { await refresh() }
            .onDisappear { task?.cancel() }
            .onChange(of: phase) { _,p in if p == .background { task?.cancel() } }
            .confirmationDialog("将此来源在本机的修改与删除写回桌面？原有非同步会话不上传。",isPresented: $confirmWrite,titleVisibility: .visible) { Button("开始双向同步") { start(.both) } }
            .confirmationDialog("恢复该来源同步前的状态？当前内容会另存恢复点，不改变桌面。",isPresented: Binding(get: { restoring != nil },set: { if !$0 { restoring = nil } }),titleVisibility: .visible) { Button("保留当前副本并恢复") { if let p = restoring { restore(p) }; restoring = nil } }
    }
    private var matching: [SyncCheckpoint] { checkpoints.filter { $0.profileID == selected?.id }.sorted { $0.at > $1.at } }
    private var unavailable: Bool { model.synchronizing || model.credentialsLocked || model.rooms.values.contains(where: \.busy) || (model.serviceSecrets[.syncToken] ?? "").isEmpty }
    @MainActor private func refresh() async { do { profiles = try await model.store?.records(SyncProfile.self,kind: "sync-profile") ?? []; checkpoints = try await model.store?.records(SyncCheckpoint.self,kind: "sync-checkpoint") ?? [] } catch { self.error = error.localizedDescription } }
    private func start(_ mode: MobileSyncMode) {
        guard !unavailable,let store = model.store else { return }; error = nil; progress = "准备同步…"; model.synchronizing = true
        let settings = model.services.sync,token = model.serviceSecrets[.syncToken] ?? ""
        task = Task { @MainActor in
            defer { model.synchronizing = false; task = nil }
            do {
                guard await model.saveServices() else { throw SyncWire.fail(model.error ?? "保存连接失败") }; try Task.checkCancellation()
                await model.flushDraft()
                let endpoint = try MobileSyncSettings.endpoint(settings.httpURL).absoluteString
                let p = profiles.first { $0.endpoint == endpoint } ?? SyncProfile(endpoint: endpoint)
                let before = try await store.syncSnapshot().managed(by: p),versions = try await store.syncVersions()
                let result = try await engine.run(settings: settings,token: token,mode: mode,profile: p,local: before,versions: versions) { text in await MainActor.run { progress = text } }
                try Task.checkCancellation(); try await store.commitSync(profile: result.profile,previous: p,before: before,after: result.after,expectedSettings: settings)
                await model.reloadSyncSource(p); await refresh(); progress = result.attachmentWarnings > 0 ? "已完成；\(result.attachmentWarnings) 个旧附件缺少有效身份，已保留可用内容" : "同步完成，恢复点已保存"
            } catch is CancellationError { progress = ""; self.error = "已取消，本机内容未替换；若曾写回桌面，重试会重新核对差分" }
            catch { progress = ""; self.error = error.localizedDescription }
        }
    }
    private func restore(_ point: SyncCheckpoint) {
        guard !model.synchronizing,!model.rooms.values.contains(where: \.busy),let store = model.store else { return }; model.synchronizing = true; error = nil
        task = Task { @MainActor in defer { model.synchronizing = false; task = nil }; do { try await store.restoreSync(point); await model.reloadSyncSource(point.previous); await refresh(); progress = "已恢复；恢复前内容仍在恢复点中" } catch { self.error = error.localizedDescription } }
    }
}
extension ChatViewModel {
    func reloadSyncSource(_ p: SyncProfile) async {
        do {
            guard let store else { return }; let all = try await store.syncSnapshot()
            let prefix = "sync:\(p.id):"
            let oldIDs = Set(topics.filter { $0.ownerId.hasPrefix(prefix) }.map(\.id))
            agents = all.agents; groups = all.groups; topics = all.topics
            topicStates = try await store.topicToolStates()
            let ids = oldIDs.union(topics.filter { $0.ownerId.hasPrefix(prefix) }.map(\.id))
            for (id,room) in rooms where ids.contains(id) || room.messages.contains(where: { $0.id.hasPrefix(prefix) }) { rooms.removeValue(forKey: id) }
            if let topic = topics.first(where: { $0.id == activeTopicID }) { await openTopic(topic) }
            else if let topic = topics.first { await openTopic(topic) }
        } catch { self.error = "同步已保存，但刷新列表失败：\(error.localizedDescription)" }
    }
}
extension ChatViewModel {
    func refreshAttachmentMetadata() async {
        do {
            guard let store else { return }; let records = try await store.messages(); let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id,$0.attachments) })
            for room in rooms.values { for message in room.messages { if let attachments = byID[message.id] { message.attachments = attachments } } }
        } catch { self.error = error.localizedDescription }
    }
}
