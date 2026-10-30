import Foundation
import Observation
import VChatCore

@MainActor @Observable final class MessageViewModel: Identifiable {
    let id: String
    let role: String
    let createdAt: Double
    var text: String
    var reasoning: String
    var status: String
    init(_ message: StoredMessage) { id = message.id; role = message.role; text = message.content; reasoning = message.reasoning; status = message.status; createdAt = message.createdAt }
    var record: StoredMessage { StoredMessage(id: id, role: role, content: text, reasoning: reasoning, status: status, createdAt: createdAt) }
}

@MainActor @Observable final class ChatViewModel {
    var messages: [MessageViewModel] = []
    var draft = ""
    var configuration: ConnectionConfiguration
    var apiKey = ""
    var logKey = ""
    var models: [String] = []
    var busy = false
    var loading = true
    var connection = "未连接"
    var pushStatus = "未连接"
    var error: String?
    var pushEvents: [String] = []
    var search = ""
    var results: [StoredMessage] = []
    var frames = 0
    var tokens = 0
    var parsingOffMain = true
    var pendingCount = 0
    @ObservationIgnored private let session = SessionActor()
    @ObservationIgnored private let vault = CredentialVault()
    @ObservationIgnored private var store: ChatStore?
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var push: Task<Void, Never>?
    @ObservationIgnored private var activeID: String?
    init() {
        if let data = UserDefaults.standard.data(forKey: "native.connection"), let saved = try? JSONDecoder().decode(ConnectionConfiguration.self, from: data) { configuration = saved }
        else { configuration = ConnectionConfiguration() }
    }
    func load() async {
        do {
            let root: URL
            if let isolated = ProcessInfo.processInfo.environment["VCHAT_DATA_DIR"] { root = URL(fileURLWithPath: isolated) }
            else { root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("VChatNative", isDirectory: true) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try await ChatStore.open(path: root.appendingPathComponent("chat.sqlite").path); store = database
            try await database.recoverInterrupted()
            messages = try await database.messages().map(MessageViewModel.init)
            pendingCount = try await database.pending()
            apiKey = try await vault.read("chat-api-key"); logKey = try await vault.read("vcp-log-key")
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    func importConnection(from url: URL) async {
        do {
            let imported = try await DesktopConnection.read(from: url)
            let oldConfiguration = configuration
            let oldAPI = apiKey
            let oldLog = logKey
            configuration = imported.configuration
            configuration.model = oldConfiguration.model
            apiKey = imported.apiKey
            logKey = imported.logKey
            if await saveConnection() { connection = "连接已导入"; error = nil }
            else { configuration = oldConfiguration; apiKey = oldAPI; logKey = oldLog }
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
    func refreshModels() async {
        do { models = try await session.models(configuration: configuration, apiKey: apiKey); if configuration.model.isEmpty { configuration.model = models.first ?? "" }; connection = "鉴权成功 · \(models.count) 个模型" }
        catch { self.error = error.localizedDescription }
    }
    func connectPush() {
        push?.cancel(); pushStatus = "正在鉴权"
        let config = configuration, key = logKey
        push = Task {
            do {
                for try await event in try await session.connectPush(configuration: config, key: key) {
                    if Task.isCancelled { return }
                    pushStatus = event.connected ? "已连接" : "未连接"
                    if event.kind != "connection_ack" { pushEvents.insert(event.text, at: 0); if pushEvents.count > 100 { pushEvents.removeLast() } }
                }
                if !Task.isCancelled { pushStatus = "未连接" }
            } catch { if !Task.isCancelled { pushStatus = error.localizedDescription } }
        }
    }
    func send() {
        guard !busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard store != nil else { error = "本机数据库尚未就绪"; return }
        guard !apiKey.isEmpty, !configuration.model.isEmpty else { error = "请先设置服务器、API Key 和模型"; return }
        let content = draft
        let user = StoredMessage(role: "user", content: content, status: "pending")
        let assistant = MessageViewModel(StoredMessage(role: "assistant", content: "", status: "connecting", createdAt: user.createdAt + 0.0001))
        let context = messages.filter { $0.status == "complete" || $0.role == "user" }.map { ChatTurn(role: $0.role, content: $0.text) } + [ChatTurn(role: "user", content: content)]
        let request = ChatRequest(configuration: configuration, apiKey: apiKey, messages: context)
        busy = true; activeID = assistant.id; error = nil
        generation = Task {
            guard let store else { return }
            do {
                try await store.enqueue(user)
                messages.append(MessageViewModel(user)); messages.append(assistant); draft = ""
                try await store.save(assistant.record)
                var lastSaved = ContinuousClock.now
                var accepted = false
                for try await update in try await session.stream(request) {
                    guard activeID == assistant.id else { return }
                    assistant.text = update.text; assistant.reasoning = update.reasoning; assistant.status = update.state.rawValue
                    frames = update.sequence; tokens = update.rawEvents; parsingOffMain = update.parserWasOffMainThread
                    switch update.state {
                    case .connecting: connection = "正在连接"
                    case .streaming: connection = "正在回复"
                    case .complete: connection = "回复完成"
                    case .stopped: connection = "已停止"
                    case .interrupted: connection = "已中断"
                    case .failed: connection = "连接失败"
                    }
                    if (update.state == .streaming || update.state == .complete) && !accepted { try await store.markSent(user.id); accepted = true; messages.first(where: { $0.id == user.id })?.status = "complete" }
                    if lastSaved.duration(to: .now) >= .milliseconds(500) || update.state != .streaming {
                        try await store.save(assistant.record); lastSaved = .now
                    }
                }
            } catch {
                assistant.status = "interrupted"; self.error = error.localizedDescription
                do { try await store.save(assistant.record) } catch { self.error = "回复已保留在内存，但本机保存失败：\(error.localizedDescription)" }
            }
            if activeID == assistant.id { busy = false; activeID = nil; generation = nil }
            pendingCount = (try? await store.pending()) ?? pendingCount
        }
    }
    func stop(background: Bool = false) async { await session.stop(interrupted: background) }
    func suspend() async { await stop(background: true); await session.disconnectPush(); push?.cancel(); pushStatus = "后台暂停" }
    func searchLocal() async {
        let query = search
        do { let found = try await store?.search(query) ?? []; if search == query { results = found } }
        catch { self.error = error.localizedDescription }
    }
}
