import Foundation
import Observation
import VChatCore
import VChatRendering

#if DEBUG && os(iOS) && targetEnvironment(simulator)
/// The system can cold-launch the app for a URLSession event *before* XCTest
/// opens its window. That process does not inherit XCUIApplication.launchEnvironment.
/// Keep the synthetic loopback port and store ID together across that launch.
struct SimulatorReplyFixture: Codable {
    static let key = "test.reply-sync-fixture.v1"
    let session: UUID, port: Int, expires: Date

    static func resolve(_ env: [String: String]) -> (endpoint: String, session: UUID?)? {
        let defaults = UserDefaults.standard
        if let endpoint = env["VCHAT_TEST_LIVE_ENDPOINT"] {
            defaults.removeObject(forKey: key)
            guard let url = URL(string: endpoint), url.scheme == "http", url.host == "localhost",
                  let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil else { return nil }
            let id = env["VCHAT_TEST_SYNC_SESSION"].flatMap(UUID.init(uuidString:))
            if let id {
                let fixture = Self(session: id, port: port, expires: Date().addingTimeInterval(600))
                defaults.set(try? JSONEncoder().encode(fixture), forKey: key)
            }
            return (endpoint, id)
        }
        guard env["VCHAT_TEST_DISCLOSURE_MESSAGE"] == nil, let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.expires > Date(),
              (1...65535).contains(saved.port) else { defaults.removeObject(forKey: key); return nil }
        if env["VCHAT_TEST_END_SYNC_SESSION"] == saved.session.uuidString { defaults.removeObject(forKey: key) }
        return ("http://localhost:\(saved.port)", saved.session)
    }
}
#endif

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
    var locationPreference: LocationMessagePreference = .automatic
    var busy = false
    var serverOwnsReply = false
    var receivesInBackground = false
    @ObservationIgnored var receivedReplyBytes = 0
    var backgroundJobID: String?
    var cancellation: SessionState?
    var cancelled: Bool { cancellation != nil }
    var connection = ""
    var frames = 0
    var pendingCount = 0
    var needsExternalReload = false
    var error: String?
    @ObservationIgnored let session = SessionActor()
    @ObservationIgnored var generation: Task<Void, Never>?
    @ObservationIgnored var draftSave: Task<Void, Never>?
    init(id: String, messages: [StoredMessage]) {
        self.id = id; self.messages = messages.map(MessageViewModel.init); depths = TurnDepths.calculate(messages)
        pendingCount = messages.filter { $0.status == "pending" }.count
    }
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
    var lastMessageTimes: [String: Double] = [:]
    var topicOrdering: TopicOrdering = {
        guard let data = UserDefaults.standard.data(forKey: "native.topic-order"),
              let saved = try? JSONDecoder().decode(TopicOrdering.self, from: data) else { return TopicOrdering() }
        return saved
    }() {
        didSet { if let data = try? JSONEncoder().encode(topicOrdering) { UserDefaults.standard.set(data, forKey: "native.topic-order") } }
    }
    var topicStates: [String:TopicToolState] = [:]
    var profile = UserProfile()
    var renderOptions = RenderOptions()
    var stickerCatalog: EmoticonCatalog?
    var catalogDeployment: URL?
    var stickerDeployment: URL? { StickerDirectories.deploymentBase(try? configuration.baseURL()) }
    var stickers: StickerContext {
        StickerContext(server: stickerDeployment, fileKey: serviceSecrets[.fileKey] ?? "",
                       catalog: catalogDeployment == stickerDeployment ? stickerCatalog : nil)
    }
    var appearance = AppearanceSettings()
    var inputPreferences = InputPreferences()
    #if os(iOS)
    private(set) var advancedReplies = AdvancedReplyConfiguration()
    #else
    var outputPreferences = OutputPreferences()
    #endif
    private var replySettings: (legacy: OutputPreferences, advanced: AdvancedReplyConfiguration?) {
        #if os(iOS)
        (.init(), advancedReplies)
        #else
        (outputPreferences, nil)
        #endif
    }
    var locationSettings = LocationSharingSettings() { didSet { locationSettingsRevision = UUID() } }
    @ObservationIgnored var locationSettingsRevision = UUID()
    var location: DeviceLocationService
    var regexRules: [RegexRule] = []
    var activeTopicID = "legacy"
    var rooms: [String: ChatRoom] = [:]
    var services = ServiceSettings()
    var serviceSecrets: [ServiceSecret: String] = [:]
    var configuration: ConnectionConfiguration
    static let endpointModePreference = "native.endpoint-mode"
    // Changing the route must not require Keychain access or commit other edits
    // in the connection form (especially an unconfirmed server address).
    func selectEndpointMode(_ mode: EndpointMode) {
        configuration.endpointMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.endpointModePreference)
    }
    var apiKey = ""
    var logKey = ""
    var models: [String] = []
    var catalog: ModelCatalog?
    var credentialsLocked = false
    var unlockingCredentials = false
    var savingConnection = false
    var connectingPush = false
    var restoringConnections = false
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
    #if os(iOS)
    @ObservationIgnored var replyTransfers = BackgroundReplyTransfers()
    @ObservationIgnored var updateReplyActivity: @MainActor (String, Int) async -> Void = { id, bytes in
        await ReplyPresentation.update(id: id, receivedBytes: bytes)
    }
    var requestedReplyTopic: String?
    private var prefersServerReplies: Bool { UserDefaults.standard.bool(forKey:ServerReplyClient.preference) }
    private var prefersBackgroundReplies: Bool { UserDefaults.standard.bool(forKey: ReplyPresentation.modeKey) }
    #else
    private var prefersServerReplies: Bool { false }
    private var prefersBackgroundReplies: Bool { false }
    #endif
    @ObservationIgnored private var loadTask: Task<Void, Never>?
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
    init(vault: CredentialVault? = nil, location: DeviceLocationService? = nil) {
        self.location = location ?? DeviceLocationService()
        let storage = CredentialVault.Persistence(rawValue: Bundle.main.object(forInfoDictionaryKey: "VChatCredentialPersistence") as? String ?? "") ?? .keychain
        self.vault = vault ?? CredentialVault(persistence: storage)
        if let data = UserDefaults.standard.data(forKey: "native.connection"), let saved = try? JSONDecoder().decode(ConnectionConfiguration.self, from: data) { configuration = saved }
        else { configuration = ConnectionConfiguration() }
        if let value = UserDefaults.standard.string(forKey: Self.endpointModePreference),
           let mode = EndpointMode(rawValue: value) { configuration.endpointMode = mode }
    }
    func load() async {
        if let loadTask { await loadTask.value; return }
        guard store == nil else { return }
        let task = Task { await loadDatabase() }
        loadTask = task
        await task.value
        loadTask = nil
    }
    private func loadDatabase() async {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
        if let (endpoint, testID) = SimulatorReplyFixture.resolve(ProcessInfo.processInfo.environment) {
            do {
                let container = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let root = container.appendingPathComponent("ReplySyncFixtures").appendingPathComponent((testID ?? UUID()).uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let database = try await ChatStore.open(path:root.appendingPathComponent("chat.sqlite").path)
                let agent = VCPAgent(id:"fixture",name:"测试"), topic = ChatTopic(id:"fixture-topic",ownerId:"fixture",title:"流式接收测试")
                try await database.put(topic,kind:"topic",id:topic.id)
                store = database; agents = [agent]; topics = [topic]
                apiKey = "fixture"; configuration = .init(server:endpoint,model:testID?.uuidString ?? "fixture")
                let room = ChatRoom(id:topic.id,messages:try await database.messages(topicID:topic.id))
                room.draft = "本机测试"; rooms[room.id] = room; activeTopicID = room.id
                try await restoreBackgroundReplies(store:database,root:root)
                renderOptions.motion = false; requestedReplyTopic = topic.id
            } catch { self.error = error.localizedDescription }
            loading = false; return
        }
        if let sample = ProcessInfo.processInfo.environment["VCHAT_TEST_DISCLOSURE_MESSAGE"] {
            let topic = ChatTopic(id:"test-disclosures",ownerId:"assistant")
            let message = StoredMessage(topicID:topic.id,role:"assistant",content:sample,reasoning:"这段单独的推理")
            agents = [VCPAgent(id:"assistant",name:"助手")]; topics = [topic]
            rooms[topic.id] = ChatRoom(id:topic.id,messages:[message]); activeTopicID = topic.id
            renderOptions.motion = false; requestedReplyTopic = topic.id; loading = false
            return
        }
        #endif
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
            #if os(iOS)
            if let saved = try await database.records(AdvancedReplyConfiguration.self,kind: "advanced-replies").first {
                advancedReplies = saved
            } else {
                let old = try await database.records(OutputPreferences.self,kind: "output-options").first ?? OutputPreferences()
                advancedReplies = try AdvancedReplyConfiguration.seeded(legacy: old)
            }
            #else
            outputPreferences = try await database.records(OutputPreferences.self, kind: "output-options").first ?? OutputPreferences()
            #endif
            locationSettings = try await database.records(LocationSharingSettings.self,kind: "location-options").first ?? LocationSharingSettings()
            services = try await database.records(ServiceSettings.self, kind: "services").first ?? ServiceSettings()
            appearance = try await database.records(AppearanceSettings.self, kind: "appearance").first ?? AppearanceSettings()
            renderOptions = try await database.records(RenderOptions.self, kind: "render-options").first ?? RenderOptions()
            if agents.isEmpty {
                let assistant = VCPAgent(id: "assistant", name: "助手")
                try await database.put(assistant, kind: "agent", id: assistant.id); agents = [assistant]
            }
            try await reloadTopicList(from: database)
            topicStates = try await database.topicToolStates()
            if topics.isEmpty {
                let topic = ChatTopic(id: "legacy", ownerId: agents[0].id, title: "第一段对话")
                try await database.put(topic, kind: "topic", id: topic.id); topics = [topic]
            }
            let previous = UserDefaults.standard.string(forKey: "native.active-topic") ?? "legacy"
            await openTopic(topics.first { $0.id == previous } ?? recentTopics(topics)[0])
            #if os(iOS)
            try await restoreBackgroundReplies(store: database, root: root)
            #endif
            await activity.load(store: database)
            await loadCatalog()
            loading = false
            credentialsLocked = true
            await loadCredentials(allowInteraction: false)
            prefetchLocation()
        } catch {
            self.error = error.localizedDescription
            #if os(iOS)
            replyTransfers.abandonWake()
            #endif
        }
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
    #if os(iOS)
    func saveAdvancedReplies(_ value: AdvancedReplyConfiguration) async throws {
        guard let store else { throw ClientError.server("本机数据库尚未就绪") }
        try await store.put(value,kind: "advanced-replies",id: "rules")
        advancedReplies = value
    }
    #else
    func saveOutputPreferences() async {
        do { try await store?.put(outputPreferences, kind: "output-options", id: "bubbles") }
        catch { self.error = error.localizedDescription }
    }
    #endif
    func saveRenderOptions() async {
        do { try await store?.put(renderOptions, kind: "render-options", id: "display") }
        catch { self.error = error.localizedDescription }
    }
    func saveAgent(_ agent: VCPAgent) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
        guard !agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "给 Agent 起一个名字"; return false }
        guard agent.contextTokenLimit.map({ $0 >= 0 }) ?? true, agent.maxOutputTokens.map({ $0 >= 0 }) ?? true else { error = "上下文预算和最大输出不能为负数"; return false }
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
    func reloadTopicList(from store: ChatStore) async throws {
        let list = try await store.topicList()
        topics = list.topics
        lastMessageTimes = list.lastMessages
    }

    func recentTopics(_ candidates: [ChatTopic]) -> [ChatTopic] {
        TopicSortMode.activity.sorted(candidates, lastMessages: lastMessageTimes)
    }

    private func noteSavedUtterance(_ message: StoredMessage) {
        guard ["user", "assistant"].contains(message.originalRole ?? message.role) else { return }
        lastMessageTimes[message.topicID] = max(lastMessageTimes[message.topicID] ?? message.createdAt, message.createdAt)
    }

    func openAgent(_ agent: VCPAgent) async {
        if let topic = recentTopics(topics.filter { $0.ownerType == "agent" && $0.ownerId == agent.id }).first { await openTopic(topic) }
        else { await createTopic(ownerID: agent.id) }
    }
    func saveGroup(_ group: VCPGroup) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
        guard let store else { error = "本机数据库尚未就绪"; return false }
        guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !group.memberIds.isEmpty else { error = "请填写群名并选择成员"; return false }
        guard group.enableContextMessageWindow != true || (1...10_000).contains(group.contextMessageWindowSize ?? 100) else { error = "群聊历史窗口需为 1–10000 条消息"; return false }
        do {
            try await store.put(group, kind: "group", id: group.id)
            if let index = groups.firstIndex(where: { $0.id == group.id }) { groups[index] = group } else { groups.append(group) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func openGroup(_ group: VCPGroup) async {
        if let topic = recentTopics(topics.filter { $0.ownerType == "group" && $0.ownerId == group.id }).first { await openTopic(topic) }
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
            if let room = rooms[topic.id] { await stopGeneration(in: room) }; await rooms[topic.id]?.generation?.value; rooms[topic.id]?.draftSave?.cancel()
            try await store?.removeTopic(topic.id); rooms.removeValue(forKey: topic.id); topics.removeAll { $0.id == topic.id }; lastMessageTimes[topic.id] = nil
            if activeTopicID == topic.id {
                if let next = recentTopics(topics).first { await openTopic(next) }
                else if let agent = mainAgent { await createTopic(ownerID: agent.id) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func importConnection(from url: URL) async {
        guard !credentialsLocked else { error = "请先解锁已有连接，再导入新配置"; return }
        do {
            let imported = try await DesktopConnection.read(from: url)
            var config = imported.configuration; config.model = imported.preferredModel ?? configuration.model
            config.endpointMode = configuration.endpointMode // desktop imports contain no route preference
            configuration = config; apiKey = imported.apiKey; logKey = imported.logKey
            if let sync = imported.syncSettings,let token = imported.syncToken {
                services.sync = sync; serviceSecrets[.syncToken] = token
            }
            guard await saveConnection() else { return }
            if imported.syncSettings != nil { guard await saveServices() else { return } }
            error = nil
        } catch { self.error = "导入失败，请选择有效的桌面连接或手机配对文件" }
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
    func attach(_ items: [ChatAttachment], to topicID: String) async {
        guard let room = rooms[topicID] else { return }
        do { try AttachmentImporter.assertCount(room.attachments.count, adding: items.count); room.attachments += items; room.draftSave?.cancel(); try await store?.put(TopicDraft(id: room.id, text: room.draft, attachments: room.attachments), kind: "draft", id: room.id); room.error = nil }
        catch { room.error = error.localizedDescription }
    }
    func detach(_ id: String) async {
        room?.attachments.removeAll { $0.id == id }; await flushDraft()
    }
    private func reserveReply(in room: ChatRoom) {
        room.backgroundJobID = UUID().uuidString
    }
    private func finishReplyTurn(in room: ChatRoom) {
        #if os(iOS)
        if let id = room.backgroundJobID {
            room.backgroundJobID = nil
            let phase: ReplyActivityAttributes.ContentState.Phase = room.cancelled ? .stopped : .interrupted
            Task { await ReplyPresentation.end(id, phase: phase) }
        }
        #endif
    }
    func send(onDraftCleared: @escaping @MainActor () -> Void = {}) {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return }
        guard let room, let topic = activeTopic, !room.busy, (!room.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !room.attachments.isEmpty), let store else { return }
        let content = room.draft
        let group = activeGroup
        let speakers = group.map { GroupRouting.speakers(group: $0, agents: agents, text: content, turn: topic.turnIndex) } ?? activeAgent.map { [$0] } ?? []
        guard !apiKey.isEmpty else { error = "请先设置聊天 API Key"; return }
        let user = StoredMessage(topicID: room.id, authorName: profile.name.isEmpty ? "我" : profile.name, role: "user", content: content, status: "pending", attachments: room.attachments)
        let config = configuration, key = apiKey, profile = profile, rules = regexRules, replies = replySettings
        room.busy = true; room.receivesInBackground = prefersBackgroundReplies; room.serverOwnsReply = room.receivesInBackground && prefersServerReplies; room.cancellation = nil; room.error = nil
        if room.receivesInBackground && !speakers.isEmpty { reserveReply(in:room) }
        room.generation = Task {
            var currentReply: MessageViewModel?
            do {
                if speakers.isEmpty { var local = user; local.status = "complete"; try await store.save(local); room.messages.append(MessageViewModel(local)) }
                else { try await store.enqueue(user); room.messages.append(MessageViewModel(user)) }
                noteSavedUtterance(user)
                if room.draft == content && room.attachments == user.attachments {
                    room.draftSave?.cancel()
                    room.draft = ""; room.attachments = []
                    if self.room === room { onDraftCleared() }
                    try await store.put(TopicDraft(id: room.id, text: ""), kind: "draft", id: room.id)
                }
                if topic.title == "新对话" { await renameTopic(topic, title: String(content.prefix(24))) }
                if speakers.isEmpty { throw ClientError.server(group?.mode == .inviteOnly ? "用 @名字 邀请群成员发言" : "这个会话没有可发言的 Agent，请在通讯录检查成员") }
                var accepted = false
                let locationPreference = room.locationPreference
                let locationContext = await prepareLocation(for: speakers,preference: locationPreference)
                room.locationPreference = .automatic
                let builder = ConversationBuilder()
                for agent in speakers {
                    guard !room.cancelled else { break }
                    let request = try await builder.request(configuration: config, apiKey: key, profile: profile, agent: agent, group: group, messages: room.messages.map(\.record), rules: rules, output: replies.legacy, location: locationContext?.settings == locationSettings && locationSettings.shares(with: agent.id,preference: locationPreference) ? locationContext : nil, locationPolicy: locationSettings.shares(with: agent.id) ? LocationRequestContext.policy(settings: locationSettings,agentID: agent.id) : nil, advancedReplies: replies.advanced, currentUserMessageID: user.id)
                    guard !room.cancelled else { break }
                    let assistant = MessageViewModel(StoredMessage(topicID: room.id, agentID: agent.id, authorName: agent.name, role: "assistant", content: "", status: "connecting"))
                    currentReply = assistant; room.messages.append(assistant); try await store.save(assistant.record)
                    noteSavedUtterance(assistant.record)
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
            finishReplyTurn(in:room)
            room.busy = false; room.generation = nil
            if room.needsExternalReload { await reloadTopicTools(changedID: room.id) }
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
        #if os(iOS)
        if room.receivesInBackground {
            if room.backgroundJobID == nil { reserveReply(in:room) }
            let job = BackgroundReplyJob(id: room.backgroundJobID!, messageID: assistant.id, topicID: room.id, userID: acceptedUser)
            room.connection = "正在接收回复"
            let ticket = try await replyTransfers.submit(job, request: request, room: room, store: store)
            await collectBackgroundReply(job, ticket: ticket, room: room, store: store)
            return
        }
        #endif
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
        let config = configuration, key = apiKey, profile = profile, rules = regexRules, replies = replySettings
        let prefix = continuing ? message.text : "", reasoning = continuing ? message.reasoning : ""
        let history = (continuing ? room.messages : Array(room.messages.dropLast())).map(\.record)
        room.busy = true; room.receivesInBackground = prefersBackgroundReplies; room.serverOwnsReply = room.receivesInBackground && prefersServerReplies; room.cancellation = nil; room.error = nil
        if room.receivesInBackground { reserveReply(in:room) }
        room.generation = Task {
            defer { finishReplyTurn(in:room); room.busy = false; room.generation = nil; room.pendingCount = room.messages.filter { $0.status == "pending" }.count; if room.needsExternalReload { Task { await self.reloadTopicTools(changedID: room.id) } } }
            do {
                let locationPreference = room.locationPreference
                let locationContext = await prepareLocation(for: [agent],preference: locationPreference)
                room.locationPreference = .automatic
                let prompt = continuing && !prefix.isEmpty ? "上一条回复在传输中断开了。请从断开的地方直接接着写，不要重复已经写过的内容，也不要解释。" : nil
                let request = try await ConversationBuilder().request(configuration: config, apiKey: key, profile: profile, agent: agent, group: group, messages: history, rules: rules, output: replies.legacy, location: locationContext, locationPolicy: locationSettings.shares(with: agent.id) ? LocationRequestContext.policy(settings: locationSettings,agentID: agent.id) : nil, advancedReplies: replies.advanced, currentUserMessageID: history.last { ($0.originalRole ?? $0.role) == "user" }?.id, transientUserPrompt: prompt)
                guard !room.cancelled else { return }
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
        do { try await store.trashMessage(message.id); room.messages.removeAll { $0.id == message.id }
            lastMessageTimes[room.id] = room.messages.lazy.filter { ["user", "assistant"].contains($0.originalRole ?? $0.role) }.map(\.createdAt).max()
            room.pendingCount = room.messages.filter { $0.status == "pending" }.count }
        catch { room.error = error.localizedDescription }
    }
    func restoreMessage(_ backup: MessageBackup) async -> Bool {
        guard !synchronizing else { error = "请等待同步完成或取消后再修改会话"; return false }
        guard let store, rooms[backup.message.topicID]?.busy != true else { return false }
        do {
            try await store.restoreMessage(backup)
            noteSavedUtterance(backup.message)
            if let room = rooms[backup.message.topicID] { room.messages.append(MessageViewModel(backup.message)); room.messages.sort { $0.createdAt < $1.createdAt }; room.pendingCount = room.messages.filter { $0.status == "pending" }.count }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func stop(background: Bool = false) async {
        guard let room else { return }
        room.cancellation = background ? .interrupted : .stopped
        await stopGeneration(in: room)
    }
    private func stopGeneration(in room: ChatRoom) async {
        #if os(iOS)
        if let id = room.backgroundJobID { replyTransfers.cancel(id) }
        #endif
        await room.session.stop(interrupted: room.cancellation == .interrupted)
    }
    func enterBackground() async {
        backgrounded = true
        await flushDraft(); guard !Task.isCancelled else { return }
        for room in Array(rooms.values) { await room.session.setBackgroundPacing(true) }
        await activity.pause(); await fileNode.pause()
    }
    func interruptForBackground() async {
        let targets = Array(rooms.values).filter { $0.busy && !$0.receivesInBackground }
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
        let wasBackgrounded = backgrounded
        backgrounded = false
        #if os(iOS)
        replyTransfers.refreshProgress()
        #endif
        for room in Array(rooms.values) { await room.session.setBackgroundPacing(false) }
        if wasBackgrounded {
            if credentialsLocked { await loadCredentials(allowInteraction: false) }
            else { await restoreRequestedConnections() }
        }
    }
    func suspend() async { await enterBackground(); await interruptForBackground() }
    func searchLocal() async {
        let query = search
        do { let found = try await store?.search(query) ?? []; if search == query { results = found } }
        catch { self.error = error.localizedDescription }
    }
}
