import Foundation
import Observation
import VChatCore
import VChatRendering

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
    var attachments: [ChatAttachment]
    let originalRole: String?
    let syncNotice: String?
    init(_ message: StoredMessage) {
        attachments = message.attachments; originalRole = message.originalRole; syncNotice = message.syncNotice
        id = message.id; topicID = message.topicID; agentID = message.agentID; authorName = message.authorName
        role = message.role; text = message.content; reasoning = message.reasoning
        status = message.status; createdAt = message.createdAt
    }
    var record: StoredMessage { StoredMessage(id: id, topicID: topicID, agentID: agentID, authorName: authorName, role: role, content: text, reasoning: reasoning, status: status, createdAt: createdAt, attachments: attachments, originalRole: originalRole, syncNotice: syncNotice) }
}
@MainActor @Observable final class ChatRoom: Identifiable {
    let id: String
    var messages: [MessageViewModel] { didSet { depths = TurnDepths.calculate(messages.map(\.record)) } }
    var depths: [String: Int] = [:]
    var draft = ""
    var attachments: [ChatAttachment] = []
    var busy = false
    var cancellation: SessionState?
    var cancelled: Bool { cancellation != nil }
    var connection = ""
    var frames = 0
    var pendingCount = 0
    var error: String?
    @ObservationIgnored let session = SessionActor()
    @ObservationIgnored var generation: Task<Void, Never>?
    @ObservationIgnored var draftSave: Task<Void, Never>?
    init(id: String, messages: [StoredMessage]) { self.id = id; self.messages = messages.map(MessageViewModel.init); depths = TurnDepths.calculate(messages) }
}
struct TopicDraft: Codable, Sendable {
    var id: String; var text: String; var attachments: [ChatAttachment] = []
    enum CodingKeys: String, CodingKey { case id, text, attachments }
    init(id: String, text: String, attachments: [ChatAttachment] = []) { self.id = id; self.text = text; self.attachments = attachments }
    init(from decoder: any Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(String.self, forKey: .id); text = try c.decode(String.self, forKey: .text); attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? [] }
}

@MainActor @Observable final class ChatViewModel {
    var agents: [VCPAgent] = []
    var groups: [VCPGroup] = []
    var topics: [ChatTopic] = []
    var profile = UserProfile()
    var renderOptions = RenderOptions()
    var appearance = AppearanceSettings()
    var inputPreferences = InputPreferences()
    var regexRules: [RegexRule] = []
    var activeTopicID = "legacy"
    var rooms: [String: ChatRoom] = [:]
    var services = ServiceSettings()
    var serviceSecrets: [ServiceSecret: String] = [:]
    var configuration: ConnectionConfiguration
    var apiKey = ""
    var logKey = ""
    var models: [String] = []
    var catalog: ModelCatalog?
    var credentialsLocked = false
    var unlockingCredentials = false
    var savingConnection = false
    var loading = true
    var backgrounded = false
    var synchronizing = false
    var fileNode = FileNodeController()
    var speech = SpeechPlayback()
    var activity = ActivityCenter()
    var pushStatus: String { activity.statuses[.log] ?? "未连接" }
    var error: String?
    var pushEvents: [String] { activity.entries.map { $0.payload.pretty } }
    var search = ""
    var results: [StoredMessage] = []
    @ObservationIgnored var connectedFolders: ConnectedFolders?
    @ObservationIgnored let network = SessionActor()
    @ObservationIgnored let vault: CredentialVault
    var credentialsInMemory: Bool { vault.persistence == .session }
    @ObservationIgnored var store: ChatStore?
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
                do { try await Task.sleep(for: .milliseconds(250)); try await self?.store?.put(TopicDraft(id: room.id, text: newValue, attachments: room.attachments), kind: "draft", id: room.id) }
                catch is CancellationError {} catch { self?.error = error.localizedDescription }
            }
        }
    }
    init(vault: CredentialVault? = nil) {
        let storage = CredentialVault.Persistence(rawValue: Bundle.main.object(forInfoDictionaryKey: "VChatCredentialPersistence") as? String ?? "") ?? .keychain
        self.vault = vault ?? CredentialVault(persistence: storage)
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
            connectedFolders = ConnectedFolders(storage: root.appendingPathComponent("connected-folders",isDirectory: true))
            try await database.recoverInterrupted()
            agents = try await database.records(VCPAgent.self, kind: "agent")
            groups = try await database.records(VCPGroup.self, kind: "group")
            profile = try await database.records(UserProfile.self, kind: "profile").first ?? UserProfile()
            regexRules = try await database.records([RegexRule].self, kind: "regex-global").first ?? []
            inputPreferences = try await database.records(InputPreferences.self, kind: "input-options").first ?? InputPreferences()
            services = try await database.records(ServiceSettings.self, kind: "services").first ?? ServiceSettings()
            appearance = try await database.records(AppearanceSettings.self, kind: "appearance").first ?? AppearanceSettings()
            renderOptions = try await database.records(RenderOptions.self, kind: "render-options").first ?? RenderOptions()
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
            await activity.load(store: database)
            await loadCatalog()
            loading = false
            // Do not call Security APIs on startup, even with a no-interaction hint.
            credentialsLocked = !credentialsInMemory && (UserDefaults.standard.data(forKey: "native.connection") != nil || UserDefaults.standard.bool(forKey: "native.secrets-exist"))
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func saveServices() async -> Bool {
        guard !credentialsLocked else { error = "请先在连接设置中解锁已有连接，再保存服务密钥"; return false }
        do {
            for name in ServiceSecret.allCases { try await vault.save(serviceSecrets[name] ?? "",name: name.rawValue) }
            try await store?.put(services,kind: "services",id: "settings")
            if !credentialsInMemory { UserDefaults.standard.set(true,forKey: "native.secrets-exist") }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveAppearance() async {
        do { try await store?.put(appearance, kind: "appearance", id: "theme") }
        catch { self.error = error.localizedDescription }
    }
    func saveRegexRules() async {
        do { try await store?.put(regexRules, kind: "regex-global", id: "rules") }
        catch { self.error = error.localizedDescription }
    }
    func displayRules(for message: MessageViewModel) -> [RegexRule] {
        regexRules + (authorAgent(for: message)?.regexRules ?? [])
    }
    func authorAgent(for message: MessageViewModel) -> VCPAgent? { AgentIdentity.author(agentID: message.agentID,name: message.authorName,topicID: message.topicID,topics: topics,agents: agents,groups: groups) }
    var modelTitle: String { ModelResolution.summary(global: configuration.model,agent: activeAgent,group: activeGroup,agents: agents) }
    func displayedText(_ message: MessageViewModel) async throws -> String { try await RegexEngine.shared.apply(message.text, rules: displayRules(for: message), scope: "frontend", role: message.role, depth: rooms[message.topicID]?.depths[message.id] ?? 0) }
    func saveInputPreferences() async {
        do { try await store?.put(inputPreferences, kind: "input-options", id: "keyboard") }
        catch { self.error = error.localizedDescription }
    }
    func saveRenderOptions() async {
        do { try await store?.put(renderOptions, kind: "render-options", id: "display") }
        catch { self.error = error.localizedDescription }
    }
    func saveAgent(_ agent: VCPAgent) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
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
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
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
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
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
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        do { try await store?.removeRecord(kind: "group", id: id); groups.removeAll { $0.id == id } }
        catch { self.error = error.localizedDescription }
    }
    func createTopic(ownerID: String, ownerType: String = "agent") async {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
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
                let room = ChatRoom(id: topic.id, messages: messages); room.draft = saved?.text ?? ""; room.attachments = saved?.attachments ?? []; rooms[topic.id] = room
            }
            guard openingID == opening else { return }
            activeTopicID = topic.id; UserDefaults.standard.set(topic.id, forKey: "native.active-topic")
        } catch { self.error = error.localizedDescription }
    }
    func flushDraft() async {
        guard let room else { return }; room.draftSave?.cancel()
        do { try await store?.put(TopicDraft(id: room.id, text: room.draft, attachments: room.attachments), kind: "draft", id: room.id) }
        catch { self.error = error.localizedDescription }
    }
    func renameTopic(_ topic: ChatTopic, title: String) async {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = topic; updated.title = title; updated.updatedAt = Date().timeIntervalSince1970
        do { try await store?.put(updated, kind: "topic", id: topic.id); if let index = topics.firstIndex(where: { $0.id == topic.id }) { topics[index] = updated } }
        catch { self.error = error.localizedDescription }
    }
    func removeTopic(_ topic: ChatTopic) async {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        do {
            rooms[topic.id]?.cancellation = .stopped
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
        guard !savingConnection else { return false }
        guard !credentialsLocked else { error = "旧连接密钥尚未解锁。请先点“解锁已有连接”，不会用空值覆盖旧密钥。"; return false }
        let config = configuration, chat = apiKey, log = logKey
        savingConnection = true; error = nil
        defer { savingConnection = false }
        do {
            _ = try config.baseURL()
            let data = try JSONEncoder().encode(config)
            try await vault.save(chat, name: "chat-api-key"); try await vault.save(log, name: "vcp-log-key")
            try await store?.put(services,kind: "services",id: "settings")
            UserDefaults.standard.set(data, forKey: "native.connection")
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
        let server = services.logServer.isEmpty ? configuration.server : services.logServer, key = logKey
        let secrets = [apiKey,logKey] + Array(serviceSecrets.values)
        Task { await activity.connect(server: server,key: key,secrets: secrets) }
    }
    func attach(_ items: [ChatAttachment], to topicID: String) async {
        guard let room = rooms[topicID] else { return }
        do { try AttachmentImporter.assertCount(room.attachments.count, adding: items.count); room.attachments += items; room.draftSave?.cancel(); try await store?.put(TopicDraft(id: room.id, text: room.draft, attachments: room.attachments), kind: "draft", id: room.id) }
        catch { room.error = error.localizedDescription }
    }
    func detach(_ id: String) async {
        room?.attachments.removeAll { $0.id == id }; await flushDraft()
    }
    func send() {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        guard let room, let topic = activeTopic, !room.busy, (!room.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !room.attachments.isEmpty), let store else { return }
        let content = room.draft
        let group = activeGroup
        let speakers = group.map { GroupRouting.speakers(group: $0, agents: agents, text: content, turn: topic.turnIndex) } ?? activeAgent.map { [$0] } ?? []
        guard !apiKey.isEmpty else { error = "请先设置聊天 API Key"; return }
        let user = StoredMessage(topicID: room.id, authorName: profile.name.isEmpty ? "我" : profile.name, role: "user", content: content, status: "pending", attachments: room.attachments)
        let config = configuration, key = apiKey, profile = profile, rules = regexRules
        room.busy = true; room.cancellation = nil; room.error = nil
        room.generation = Task {
            var currentReply: MessageViewModel?
            do {
                room.draftSave?.cancel()
                if speakers.isEmpty { var local = user; local.status = "complete"; try await store.save(local); room.messages.append(MessageViewModel(local)) }
                else { try await store.enqueue(user); room.messages.append(MessageViewModel(user)) }
                room.draft = ""; room.attachments = []; try await store.put(TopicDraft(id: room.id, text: ""), kind: "draft", id: room.id)
                if topic.title == "新对话" { await renameTopic(topic, title: String(content.prefix(24))) }
                if speakers.isEmpty { throw ClientError.server(group?.mode == .inviteOnly ? "用 @名字 邀请群成员发言" : "这个会话没有可发言的 Agent，请在通讯录检查成员") }
                var accepted = false
                let builder = ConversationBuilder()
                for agent in speakers {
                    guard !room.cancelled else { break }
                    let request = try await builder.request(configuration: config, apiKey: key, profile: profile, agent: agent, group: group, messages: room.messages.map(\.record), rules: rules)
                    guard !room.cancelled else { break }
                    let assistant = MessageViewModel(StoredMessage(topicID: room.id, agentID: agent.id, authorName: agent.name, role: "assistant", content: "", status: "connecting"))
                    currentReply = assistant; room.messages.append(assistant); try await store.save(assistant.record)
                    try await receive(request, into: assistant, room: room, store: store, acceptedUser: accepted ? nil : user.id)
                    if room.messages.first(where: { $0.id == user.id })?.status == "complete" { accepted = true }
                    if assistant.status != "complete" { break }
                }
            } catch {
                room.error = error.localizedDescription
                if let assistant = currentReply {
                    assistant.status = room.cancellation?.rawValue ?? "interrupted"
                    do { try await store.save(assistant.record) } catch { room.error = "\(room.error ?? "")；本机保存失败：\(error.localizedDescription)" }
                }
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
    func receive(_ request: ChatRequest, into assistant: MessageViewModel, room: ChatRoom, store: ChatStore, prefix: String = "", reasoningPrefix: String = "", acceptedUser: String? = nil) async throws {
        if let cancellation = room.cancellation {
            assistant.status = cancellation.rawValue; room.connection = cancellation == .stopped ? "已停止" : "已中断"
            try await store.save(assistant.record); return
        }
        var lastSaved = ContinuousClock.now, accepted = false
        for try await update in try await room.session.stream(request, prefix: prefix, reasoningPrefix: reasoningPrefix) {
            assistant.text = update.text; assistant.reasoning = update.reasoning; assistant.status = update.state.rawValue
            room.frames += 1
            let next: String = switch update.state {
            case .connecting: "正在连接"; case .streaming: "\(assistant.authorName) 正在回复"; case .complete: "回复完成"
            case .stopped: "已停止"; case .interrupted: "已中断"; case .failed: "连接失败"
            }
            if room.connection != next { room.connection = next }
            if let id = acceptedUser, !accepted, [.streaming, .complete].contains(update.state) { try await store.markSent(id); accepted = true; room.messages.first { $0.id == id }?.status = "complete" }
            if lastSaved.duration(to: .now) >= .milliseconds(500) || update.state != .streaming { try await store.save(assistant.record); lastSaved = .now }
        }
    }
    func regenerate(_ message: MessageViewModel, continuing: Bool) {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        guard let room = rooms[message.topicID], let topic = topics.first(where: { $0.id == room.id }), !room.busy, room.messages.last?.id == message.id, message.role == "assistant", let store else { return }
        guard !apiKey.isEmpty else { error = "请先设置聊天 API Key"; return }
        guard let agent = authorAgent(for: message) else { room.error = "找不到写这条回复的 Agent"; return }
        let group = groups.first { $0.id == topic.ownerId && topic.ownerType == "group" }
        let config = configuration, key = apiKey, profile = profile, rules = regexRules
        let prefix = continuing ? message.text : "", reasoning = continuing ? message.reasoning : ""
        let history = (continuing ? room.messages : Array(room.messages.dropLast())).map(\.record)
        room.busy = true; room.cancellation = nil; room.error = nil
        room.generation = Task {
            defer { room.busy = false; room.generation = nil; room.pendingCount = room.messages.filter { $0.status == "pending" }.count }
            do {
                let built = try await ConversationBuilder().request(configuration: config, apiKey: key, profile: profile, agent: agent, group: group, messages: history, rules: rules)
                guard !room.cancelled else { return }
                let prompt = ChatTurn(role: "user", content: "上一条回复在传输中断开了。请从断开的地方直接接着写，不要重复已经写过的内容，也不要解释。")
                let request = ChatRequest(configuration: built.configuration, apiKey: built.apiKey, messages: built.messages + (continuing && !prefix.isEmpty ? [prompt] : []), temperature: built.temperature)
                var record = message.record; record.content = prefix; record.reasoning = reasoning; record.status = "connecting"
                try await store.reviseMessage(record)
                message.text = prefix; message.reasoning = reasoning; message.status = "connecting"
                let pending = room.messages.last { $0.role == "user" && $0.status == "pending" }?.id
                try await receive(request, into: message, room: room, store: store, prefix: prefix, reasoningPrefix: reasoning, acceptedUser: pending)
            } catch {
                message.status = room.cancellation?.rawValue ?? "interrupted"; room.error = error.localizedDescription
                do { try await store.save(message.record) } catch { room.error = "本机保存失败：\(error.localizedDescription)" }
            }
        }
    }
    func editMessage(_ message: MessageViewModel, text: String) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
        guard let room = rooms[message.topicID], !room.busy, let store else { return false }
        do { var record = message.record; record.content = text; try await store.reviseMessage(record); message.text = text; return true }
        catch { room.error = error.localizedDescription; return false }
    }
    func trashMessage(_ message: MessageViewModel) async {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        guard let room = rooms[message.topicID], !room.busy, let store else { return }
        do { try await store.trashMessage(message.id); room.messages.removeAll { $0.id == message.id }; room.pendingCount = room.messages.filter { $0.status == "pending" }.count }
        catch { room.error = error.localizedDescription }
    }
    func restoreMessage(_ backup: MessageBackup) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
        guard let store, rooms[backup.message.topicID]?.busy != true else { return false }
        do {
            try await store.restoreMessage(backup)
            if let room = rooms[backup.message.topicID] { room.messages.append(MessageViewModel(backup.message)); room.messages.sort { $0.createdAt < $1.createdAt }; room.pendingCount = room.messages.filter { $0.status == "pending" }.count }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func stop(background: Bool = false) async { room?.cancellation = background ? .interrupted : .stopped; await room?.session.stop(interrupted: background) }
    func enterBackground() async {
        backgrounded = true
        await flushDraft(); guard !Task.isCancelled else { return }
        for room in Array(rooms.values) { await room.session.setBackgroundPacing(true) }
        await activity.pause(); await fileNode.pause()
    }
    func interruptForBackground() async {
        let targets = Array(rooms.values).filter { $0.busy }
        for room in targets { room.cancellation = .interrupted; await room.session.stop(interrupted: true) }
        for room in targets {
            await room.generation?.value
            for message in room.messages where ["connecting","streaming"].contains(message.status) {
                message.status = "interrupted"
                do { try await store?.save(message.record) } catch { room.error = "本机保存失败：\(error.localizedDescription)" }
            }
        }
        await flushDraft()
    }
    func enterForeground() async {
        backgrounded = false
        for room in Array(rooms.values) { await room.session.setBackgroundPacing(false) }
        if activity.enabled && !logKey.isEmpty { connectPush() }
        if fileNode.active,let folders = connectedFolders { await fileNode.start(settings: services.fileNode,key: serviceSecrets[.fileNodeKey] ?? "",folders: folders) }
    }
    func suspend() async { await enterBackground(); await interruptForBackground() }
    func searchLocal() async {
        let query = search
        do { let found = try await store?.search(query) ?? []; if search == query { results = found } }
        catch { self.error = error.localizedDescription }
    }
}
