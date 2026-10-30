import Foundation
import Observation
import VChatCore

@MainActor @Observable final class MessageViewModel: Identifiable {
    let id: String
    let topicID: String
    let agentID: String
    let authorName: String
    let role: String
    let createdAt: Double
    var text: String
    var reasoning: String
    var status: String
    init(_ message: StoredMessage) {
        id = message.id; topicID = message.topicID; agentID = message.agentID; authorName = message.authorName
        role = message.role; text = message.content; reasoning = message.reasoning
        status = message.status; createdAt = message.createdAt
    }
    var record: StoredMessage { StoredMessage(id: id, topicID: topicID, agentID: agentID, authorName: authorName, role: role, content: text, reasoning: reasoning, status: status, createdAt: createdAt) }
}
@MainActor @Observable final class ChatRoom: Identifiable {
    let id: String
    var messages: [MessageViewModel]
    var draft = ""
    var busy = false
    var cancelled = false
    var connection = ""
    var frames = 0
    var pendingCount = 0
    @ObservationIgnored let session = SessionActor()
    @ObservationIgnored var generation: Task<Void, Never>?
    @ObservationIgnored var draftSave: Task<Void, Never>?
    init(id: String, messages: [StoredMessage]) { self.id = id; self.messages = messages.map(MessageViewModel.init) }
}
struct TopicDraft: Codable, Sendable { var id: String; var text: String }

@MainActor @Observable final class ChatViewModel {
    var agents: [VCPAgent] = []
    var groups: [VCPGroup] = []
    var topics: [ChatTopic] = []
    var profile = UserProfile()
    var activeTopicID = "legacy"
    var rooms: [String: ChatRoom] = [:]
    var configuration: ConnectionConfiguration
    var apiKey = ""
    var logKey = ""
    var models: [String] = []
    var catalog: ModelCatalog?
    var loading = true
    var pushStatus = "未连接"
    var error: String?
    var pushEvents: [String] = []
    var search = ""
    var results: [StoredMessage] = []
    @ObservationIgnored let network = SessionActor()
    @ObservationIgnored let vault = CredentialVault()
    @ObservationIgnored var store: ChatStore?
    @ObservationIgnored private var push: Task<Void, Never>?
    @ObservationIgnored private var openingID: UUID?
    var room: ChatRoom? { rooms[activeTopicID] }
    var activeTopic: ChatTopic? { topics.first { $0.id == activeTopicID } }
    var activeAgent: VCPAgent? { agents.first { $0.id == activeTopic?.ownerId } }
    var activeGroup: VCPGroup? { groups.first { $0.id == activeTopic?.ownerId && activeTopic?.ownerType == "group" } }
    var ownerName: String { activeGroup?.name ?? activeAgent?.name ?? "会话" }
    var mainAgent: VCPAgent? { agents.first { $0.id == profile.mainAgentID } ?? agents.first }
    var messages: [MessageViewModel] { room?.messages ?? [] }
    var busy: Bool { room?.busy ?? false }
    var frames: Int { room?.frames ?? 0 }
    var connection: String { room?.connection ?? "" }
    var pendingCount: Int { room?.pendingCount ?? 0 }
    var draft: String {
        get { room?.draft ?? "" }
        set {
            guard let room else { return }
            room.draft = newValue; room.draftSave?.cancel()
            room.draftSave = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)); try await self?.store?.put(TopicDraft(id: room.id, text: newValue), kind: "draft", id: room.id) }
                catch is CancellationError {} catch { self?.error = error.localizedDescription }
            }
        }
    }
    init() {
        if let data = UserDefaults.standard.data(forKey: "native.connection"), let saved = try? JSONDecoder().decode(ConnectionConfiguration.self, from: data) { configuration = saved }
        else { configuration = ConnectionConfiguration() }
    }
    func load() async {
        guard store == nil else { return }
        do {
            let root: URL
            if let isolated = ProcessInfo.processInfo.environment["VCHAT_DATA_DIR"] { root = URL(fileURLWithPath: isolated) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(Bundle.main.bundleIdentifier == "app.vcpchat.native" ? "VChatNative" : (Bundle.main.bundleIdentifier ?? "VChatNative"), isDirectory: true) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try await ChatStore.open(path: root.appendingPathComponent("chat.sqlite").path); store = database
            try await database.recoverInterrupted()
            agents = try await database.records(VCPAgent.self, kind: "agent")
            groups = try await database.records(VCPGroup.self, kind: "group")
            profile = try await database.records(UserProfile.self, kind: "profile").first ?? UserProfile()
            if agents.isEmpty {
                let assistant = VCPAgent(id: "assistant", name: "助手")
                try await database.put(assistant, kind: "agent", id: assistant.id); agents = [assistant]
            }
            topics = try await database.records(ChatTopic.self, kind: "topic")
            if topics.isEmpty {
                let topic = ChatTopic(id: "legacy", ownerId: agents[0].id, title: "第一段对话")
                try await database.put(topic, kind: "topic", id: topic.id); topics = [topic]
            }
            let previous = UserDefaults.standard.string(forKey: "native.active-topic") ?? "legacy"
            await openTopic(topics.first { $0.id == previous } ?? topics[0])
            await loadCatalog()
            loading = false
            // Local-first: a system Keychain confirmation must not hide local messages or drafts.
            apiKey = try await vault.read("chat-api-key"); logKey = try await vault.read("vcp-log-key")
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func saveAgent(_ agent: VCPAgent) async -> Bool {
        guard !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "给 Agent 起一个名字"; return false }
        do {
            try await store?.put(agent, kind: "agent", id: agent.id)
            if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveProfile(_ profile: UserProfile) async -> Bool {
        guard let store else { error = "本机数据库尚未就绪"; return false }
        do { try await store.put(profile, kind: "profile", id: "me"); self.profile = profile; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func setMainAgent(_ id: String) async {
        let old = profile
        do { profile.mainAgentID = id; try await store?.put(profile, kind: "profile", id: "me") }
        catch { profile = old; self.error = error.localizedDescription }
    }
    func removeAgent(_ id: String) async {
        guard agents.count > 1 else { error = "至少保留一位 Agent"; return }
        do {
            // Keep the topics and messages; deleting a contact must not erase conversation history.
            try await store?.removeRecord(kind: "agent", id: id); agents.removeAll { $0.id == id }
            if profile.mainAgentID == id, let first = agents.first { await setMainAgent(first.id) }
        } catch { self.error = error.localizedDescription }
    }
    func openAgent(_ agent: VCPAgent) async {
        if let topic = topics.filter({ $0.ownerType == "agent" && $0.ownerId == agent.id }).max(by: { $0.updatedAt < $1.updatedAt }) { await openTopic(topic) }
        else { await createTopic(ownerID: agent.id) }
    }
    func saveGroup(_ group: VCPGroup) async -> Bool {
        guard let store else { error = "本机数据库尚未就绪"; return false }
        guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !group.memberIds.isEmpty else { error = "请填写群名并选择成员"; return false }
        do {
            try await store.put(group, kind: "group", id: group.id)
            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group } else { groups.append(group) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func openGroup(_ group: VCPGroup) async {
        if let topic = topics.filter({ $0.ownerType == "group" && $0.ownerId == group.id }).max(by: { $0.updatedAt < $1.updatedAt }) { await openTopic(topic) }
        else { await createTopic(ownerID: group.id, ownerType: "group") }
    }
    func removeGroup(_ id: String) async {
        do { try await store?.removeRecord(kind: "group", id: id); groups.removeAll { $0.id == id } }
        catch { self.error = error.localizedDescription }
    }
    func createTopic(ownerID: String, ownerType: String = "agent") async {
        let topic = ChatTopic(ownerType: ownerType, ownerId: ownerID)
        do { try await store?.put(topic, kind: "topic", id: topic.id); topics.insert(topic, at: 0); await openTopic(topic) }
        catch { self.error = error.localizedDescription }
    }
    func openTopic(_ topic: ChatTopic) async {
        let opening = UUID(); openingID = opening
        await flushDraft()
        do {
            if rooms[topic.id] == nil {
                let messages = try await store?.messages(topicID: topic.id) ?? []
                let saved = try await store?.records(TopicDraft.self, kind: "draft").first { $0.id == topic.id }
                let room = ChatRoom(id: topic.id, messages: messages); room.draft = saved?.text ?? ""; rooms[topic.id] = room
            }
            guard openingID == opening else { return }
            activeTopicID = topic.id; UserDefaults.standard.set(topic.id, forKey: "native.active-topic")
        } catch { self.error = error.localizedDescription }
    }
    func flushDraft() async {
        guard let room else { return }; room.draftSave?.cancel()
        do { try await store?.put(TopicDraft(id: room.id, text: room.draft), kind: "draft", id: room.id) }
        catch { self.error = error.localizedDescription }
    }
    func renameTopic(_ topic: ChatTopic, title: String) async {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = topic; updated.title = title; updated.updatedAt = Date().timeIntervalSince1970
        do { try await store?.put(updated, kind: "topic", id: topic.id); if let index = topics.firstIndex(where: { $0.id == topic.id }) { topics[index] = updated } }
        catch { self.error = error.localizedDescription }
    }
    func removeTopic(_ topic: ChatTopic) async {
        do {
            await rooms[topic.id]?.session.stop(); await rooms[topic.id]?.generation?.value; rooms[topic.id]?.draftSave?.cancel()
            try await store?.removeTopic(topic.id); rooms.removeValue(forKey: topic.id); topics.removeAll { $0.id == topic.id }
            if activeTopicID == topic.id {
                if let next = topics.first { await openTopic(next) }
                else if let agent = mainAgent { await createTopic(ownerID: agent.id) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func importConnection(from url: URL) async {
        do {
            let imported = try await DesktopConnection.read(from: url)
            var config = imported.configuration; config.model = configuration.model
            configuration = config; apiKey = imported.apiKey; logKey = imported.logKey
            if await saveConnection() { error = nil }
        } catch { self.error = "导入失败，请选择桌面 VCPChat 的连接设置文件" }
    }
    func saveConnection() async -> Bool {
        do {
            _ = try configuration.baseURL()
            try await vault.save(apiKey, name: "chat-api-key"); try await vault.save(logKey, name: "vcp-log-key")
            UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: "native.connection")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadCatalog() async {
        guard let endpoint = try? configuration.endpoint("v1/models").absoluteString else { catalog = nil; models = []; return }
        do {
            let cached = try await store?.records(ModelCatalog.self, kind: "modelCatalog").first { $0.endpoint == endpoint }
            guard (try? configuration.endpoint("v1/models").absoluteString) == endpoint else { return }
            catalog = cached; models = cached?.ids ?? []
        } catch { self.error = error.localizedDescription }
    }
    func rememberModel(_ id: String) async {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let endpoint = try configuration.endpoint("v1/models").absoluteString
            var updated = catalog?.endpoint == endpoint ? catalog! : ModelCatalog(endpoint: endpoint, ids: models)
            updated.select(id); try await store?.put(updated, kind: "modelCatalog", id: endpoint); catalog = updated
        } catch { self.error = error.localizedDescription }
    }
    func refreshModels() async {
        let config = configuration
        do {
            let endpoint = try config.endpoint("v1/models").absoluteString
            let fetched = try await network.models(configuration: config, apiKey: apiKey)
            let old = try await store?.records(ModelCatalog.self, kind: "modelCatalog").first { $0.endpoint == endpoint }
            let updated = ModelCatalog(endpoint: endpoint, ids: fetched, recent: old?.recent ?? [])
            try await store?.put(updated, kind: "modelCatalog", id: endpoint)
            if (try? configuration.endpoint("v1/models").absoluteString) == endpoint { catalog = updated; models = updated.ids; if configuration.model.isEmpty { configuration.model = updated.ids.first ?? "" } }
        } catch { self.error = error.localizedDescription }
    }
    func connectPush() {
        push?.cancel(); pushStatus = "正在鉴权"
        let config = configuration, key = logKey
        push = Task {
            do {
                for try await event in try await network.connectPush(configuration: config, key: key) {
                    if Task.isCancelled { return }; pushStatus = event.connected ? "已连接" : "未连接"
                    if event.kind != "connection_ack" { pushEvents.insert(event.text, at: 0); if pushEvents.count > 200 { pushEvents.removeLast() } }
                }
                if !Task.isCancelled { pushStatus = "未连接" }
            } catch { if !Task.isCancelled { pushStatus = error.localizedDescription } }
        }
    }
    func send() {
        guard let room, let topic = activeTopic, !room.busy, !room.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let store else { return }
        let content = room.draft
        let group = activeGroup
        let speakers = group.map { GroupRouting.speakers(group: $0, agents: agents, text: content, turn: topic.turnIndex) } ?? activeAgent.map { [$0] } ?? []
        guard !apiKey.isEmpty else { error = "请先设置聊天 API Key"; return }
        let user = StoredMessage(topicID: room.id, authorName: profile.name.isEmpty ? "我" : profile.name, role: "user", content: content, status: "pending")
        let config = configuration, key = apiKey, profile = profile
        room.busy = true; room.cancelled = false; error = nil
        room.generation = Task {
            var currentReply: MessageViewModel?
            do {
                room.draftSave?.cancel()
                if speakers.isEmpty { var local = user; local.status = "complete"; try await store.save(local); room.messages.append(MessageViewModel(local)) }
                else { try await store.enqueue(user); room.messages.append(MessageViewModel(user)) }
                room.draft = ""; try await store.put(TopicDraft(id: room.id, text: ""), kind: "draft", id: room.id)
                if topic.title == "新对话" { await renameTopic(topic, title: String(content.prefix(24))) }
                if speakers.isEmpty { throw ClientError.server(group?.mode == .inviteOnly ? "用 @名字 邀请群成员发言" : "这个会话没有可发言的 Agent，请在通讯录检查成员") }
                var accepted = false
                let builder = ConversationBuilder()
                for agent in speakers {
                    guard !room.cancelled else { break }
                    let request = try await builder.request(configuration: config, apiKey: key, profile: profile, agent: agent, group: group, messages: room.messages.map(\.record))
                    let assistant = MessageViewModel(StoredMessage(topicID: room.id, agentID: agent.id, authorName: agent.name, role: "assistant", content: "", status: "connecting"))
                    currentReply = assistant; room.messages.append(assistant); try await store.save(assistant.record)
                    var lastSaved = ContinuousClock.now
                    for try await update in try await room.session.stream(request) {
                        assistant.text = update.text; assistant.reasoning = update.reasoning; assistant.status = update.state.rawValue
                        room.frames += 1
                        let nextStatus: String = switch update.state {
                        case .connecting: "正在连接"; case .streaming: "\(agent.name) 正在回复"; case .complete: "回复完成"
                        case .stopped: "已停止"; case .interrupted: "已中断"; case .failed: "连接失败"
                        }
                        if room.connection != nextStatus { room.connection = nextStatus }
                        if (update.state == .streaming || update.state == .complete) && !accepted { try await store.markSent(user.id); accepted = true; room.messages.first(where: { $0.id == user.id })?.status = "complete" }
                        if lastSaved.duration(to: .now) >= .milliseconds(500) || update.state != .streaming { try await store.save(assistant.record); lastSaved = .now }
                    }
                    if assistant.status != "complete" { break }
                }
            } catch {
                if let assistant = currentReply {
                    assistant.status = "interrupted"
                    do { try await store.save(assistant.record) } catch { self.error = "本机保存失败：\(error.localizedDescription)" }
                }
                self.error = error.localizedDescription
            }
            room.busy = false; room.generation = nil
            room.pendingCount = room.messages.filter { $0.status == "pending" }.count
            if var current = topics.first(where: { $0.id == topic.id }) {
                if group != nil { current.turnIndex += 1 }; current.updatedAt = Date().timeIntervalSince1970
                do { try await store.put(current, kind: "topic", id: current.id); if let index = topics.firstIndex(where: { $0.id == current.id }) { topics[index] = current } }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func stop(background: Bool = false) async { room?.cancelled = true; await room?.session.stop(interrupted: background) }
    func suspend() async {
        await flushDraft()
        for room in rooms.values { room.cancelled = true; await room.session.stop(interrupted: true) }
        await network.disconnectPush(); push?.cancel(); pushStatus = "后台暂停"
    }
    func searchLocal() async {
        let query = search
        do { let found = try await store?.search(query) ?? []; if search == query { results = found } }
        catch { self.error = error.localizedDescription }
    }
}
