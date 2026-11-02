import SwiftUI
import Observation
import VChatCore
@MainActor @Observable final class FileNodeController {
    var status = "未连接"
    var active = false
    @ObservationIgnored private var node: MobileFileNode?
    @ObservationIgnored private var task: Task<Void,Never>?
    func start(settings: FileNodeSettings,key: String,folders: ConnectedFolders,store: ChatStore? = nil,rerank: RecallRerankSettings = .init(),rerankKey: String = "",topicChanged: (@Sendable (String) async -> Void)? = nil) async {
        await stop(); active = true; let node = MobileFileNode(folders: folders,store: store,rerank: rerank,rerankKey: rerankKey,topicChanged: topicChanged); self.node = node
        do { let updates = try await node.start(settings,key: key); task = Task { for await value in updates { if Task.isCancelled { return }; status = value } } }
        catch { active = false; status = error.localizedDescription }
    }
    func pause() async { await node?.stop(); task?.cancel(); task = nil; if active { status = "后台暂停" } }
    func stop() async { active = false; await node?.stop(); task?.cancel(); task = nil; status = "未连接" }
}
struct FileNodeView: View {
    @Bindable var model: ChatViewModel
    @State private var error: String?
    @FocusState private var focusedField: Field?
    private enum Field: Int {
        case server, key, name, rerankServer, rerankModel, rerankKey
        // Each configuration block has its own last field. Do not jump across
        // the Agent permission list into an unmounted optional section.
        var previous: Self? { self == .rerankServer ? nil : Self(rawValue: rawValue - 1) }
        var next: Self? { self == .name ? nil : Self(rawValue: rawValue + 1) }
    }
    var body: some View {
        Form {
            Section("移动版 FileOperator") {
                Text("向 VCP 发布本设备的文件操作能力。Agent 只能操作你在“连接文件夹”中单独授权的目录，默认不授权任何目录。").font(.callout).foregroundStyle(.secondary)
                TextField("VCP 分布式服务地址",text: $model.services.fileNode.server)
                    .focused($focusedField,equals: .server).submitLabel(.next).autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                SecureField("分布式 Key",text: Binding(get: { model.serviceSecrets[.fileNodeKey] ?? "" },set: { model.serviceSecrets[.fileNodeKey] = $0 }))
                    .focused($focusedField,equals: .key).submitLabel(.next)
                TextField("设备名称",text: $model.services.fileNode.name)
                    .focused($focusedField,equals: .name).submitLabel(.done)
                LabeledContent("状态",value: model.fileNode.status)
                Button(model.fileNode.active ? "保存并重新发布工具" : "保存并连接") { Task { await model.connectMobileTools(); error = model.error } }.workspaceRowAction()
                Button("停止发布") { Task { await model.disconnectMobileTools(); error = model.error } }.workspaceRowAction().disabled(!model.services.fileNode.enabled && !model.fileNode.active)
                Text("iPhone 退到后台时暂停节点；回到前台可重新连接。持续运行的节点适合放在 Mac 或服务器。").font(.caption).foregroundStyle(.secondary)
            }
            Section("话题与回忆工具") {
                Toggle("TopicMemo · 读取历史话题",isOn: $model.services.fileNode.topicTools.memo)
                Toggle("DeepMemo · 检索聊天上下文",isOn: $model.services.fileNode.topicTools.deepMemo)
                Toggle("TopicSponsor · 创建与回复话题",isOn: $model.services.fileNode.topicTools.sponsor)
                Text("修改后点上方“保存并连接”生效。每台设备发布独立工具名；与Mac历史及服务器日记分开。手机退出后台后需回前台提供服务。").font(.caption).foregroundStyle(.secondary)
            }
            Section("授权访问的 Agent") {
                ForEach(model.agents) { agent in
                    VStack(alignment: .leading,spacing: 8) {
                        Text(agent.name).font(.headline)
                        Toggle("允许读取话题与检索",isOn: permission(agent.id,writing: false))
                        Toggle("允许创建和追加回复",isOn: permission(agent.id,writing: true)).disabled(!model.services.fileNode.topicTools.sponsor)
                    }.padding(.vertical,4)
                }
                Text("默认不授权。写权限同时允许读取；话题锁定和正在生成状态仍会独立校验。这里只开放话题能力，不开放Agent提示词或配置修改。").font(.caption).foregroundStyle(.secondary)
            }
            Section("DeepMemo 精排（可选）") {
                Toggle("允许将命中片段发送到精排服务",isOn: $model.services.recallRerank.enabled)
                TextField("精排服务基础地址",text: $model.services.recallRerank.server)
                    .focused($focusedField,equals: .rerankServer).submitLabel(.next).autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                TextField("精排模型",text: $model.services.recallRerank.model)
                    .focused($focusedField,equals: .rerankModel).submitLabel(.next).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField("精排 Key",text: Binding(get: { model.serviceSecrets[.recallRerankKey] ?? "" },set: { model.serviceSecrets[.recallRerankKey] = $0 }))
                    .focused($focusedField,equals: .rerankKey).submitLabel(.done)
                Text("使用兼容 /v1/rerank 的服务。关闭时只在本机检索；工具显式要求精排但未配置时返回错误，不改用其他来源。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).navigationTitle("移动工具节点")
        .scrollDismissesKeyboard(.interactively)
        .onSubmit { focusedField = focusedField?.next }
        .onDisappear { focusedField = nil }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { focusedField = focusedField?.previous } label: {
                    Image(systemName: "chevron.up").frame(width: 44,height: 44).contentShape(Rectangle())
                }.accessibilityLabel("上一个输入框").disabled(focusedField?.previous == nil)
                Button { focusedField = focusedField?.next } label: {
                    Image(systemName: "chevron.down").frame(width: 44,height: 44).contentShape(Rectangle())
                }.accessibilityLabel("下一个输入框").disabled(focusedField?.next == nil)
                Spacer()
                Button { focusedField = nil } label: {
                    Text("完成").fontWeight(.semibold).frame(minWidth: 60,minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("收起键盘")
            }
        }
        #endif
    }
    private func permission(_ id: String,writing: Bool) -> Binding<Bool> {
        Binding(get: { writing ? model.services.fileNode.topicTools.writableAgents.contains(id) : model.services.fileNode.topicTools.readers.contains(id) },set: { on in
            if writing {
                if on { model.services.fileNode.topicTools.writableAgents.insert(id); model.services.fileNode.topicTools.readableAgents.insert(id) }
                else { model.services.fileNode.topicTools.writableAgents.remove(id) }
            } else if on { model.services.fileNode.topicTools.readableAgents.insert(id) }
            else { model.services.fileNode.topicTools.readableAgents.remove(id); model.services.fileNode.topicTools.writableAgents.remove(id) }
        })
    }
}

extension ChatViewModel {
    func connectMobileTools(persist: Bool = true) async {
        guard let folders = connectedFolders,let store else { error = "本机数据尚未就绪"; return }
        if persist {
            do { _ = try MobileFileTool.endpoint(server: services.fileNode.server,key: serviceSecrets[.fileNodeKey] ?? "") }
            catch { self.error = error.localizedDescription; return }
            let previous = services.fileNode.enabled
            services.fileNode.enabled = true
            guard await saveServices() else { services.fileNode.enabled = previous; return }
        }
        guard !backgrounded else { fileNode.status = "后台暂停"; return }
        await fileNode.start(settings: services.fileNode,key: serviceSecrets[.fileNodeKey] ?? "",folders: folders,store: store,rerank: services.recallRerank,rerankKey: serviceSecrets[.recallRerankKey] ?? "",topicChanged: { [weak self] id in await self?.reloadTopicTools(changedID: id) })
    }
    func reloadTopicTools(changedID: String) async {
        do {
            guard let store else { return }
            topics = try await store.records(ChatTopic.self,kind: "topic")
            topicStates = try await store.topicToolStates()
            if let room = rooms[changedID] {
                if room.busy { room.needsExternalReload = true }
                else {
                    let messages = try await store.messages(topicID: changedID)
                    if room.busy { room.needsExternalReload = true }
                    else if rooms[changedID] === room { room.messages = messages.map(MessageViewModel.init); room.needsExternalReload = false }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func setTopicLocked(_ topic: ChatTopic,locked: Bool) async {
        guard !synchronizing else { error = "请等待同步结束后修改话题权限"; return }
        do { try await store?.updateTopicToolFlags(topicID: topic.id,locked: locked); await reloadTopicTools(changedID: topic.id) }
        catch { self.error = error.localizedDescription }
    }
    func markTopicRead(_ id: String) async {
        guard var state = topicStates[id],state.unread else { return }; state.unread = false
        do { try await store?.updateTopicToolFlags(topicID: id,markRead: true); topicStates[id] = state; if let i = topics.firstIndex(where: { $0.id == id }) { topics[i].unread = false } }
        catch { self.error = error.localizedDescription }
    }
}
