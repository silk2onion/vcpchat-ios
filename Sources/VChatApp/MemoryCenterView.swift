import SwiftUI
import Observation
import VChatCore
import VChatRendering

private struct MemoryFolderPreferences: Codable, Sendable {
    var order: [String] = []
    var hidden: Set<String> = []
}
private struct MemoryDraft: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    var folder = ""
    var file = ""
    var content = ""
    var date = Date()
    var tags = ""
    var author = ""
    var original: MemoryDocument?
}
private struct MemoryEdge: Hashable { var from: String; var to: String }

@MainActor @Observable private final class MemoryCenterModel {
    @ObservationIgnored let app: ChatViewModel
    @ObservationIgnored let client = DailyNotesClient()
    @ObservationIgnored let tools = MemoryHumanTools()
    @ObservationIgnored private var revision = UUID()
    var folders: [String] = []
    var preferences = MemoryFolderPreferences()
    var folder = ""
    var query = ""
    var scope = 0
    var notes: [RemoteNote] = []
    var semanticOutput = ""
    var workbench: [RemoteNote] = []
    var recovery: [MemoryRecoveryPoint] = []
    var drafts: [MemoryDraft] = []
    var loading = false
    var working = false
    var error: String?
    var notice = ""
    init(_ app: ChatViewModel) { self.app = app }
    var visibleFolders: [String] {
        let available = Set(folders)
        let ordered = preferences.order.filter { available.contains($0) }
        return (ordered + folders.filter { !ordered.contains($0) }.sorted()).filter { !preferences.hidden.contains($0) }
    }
    func connection() throws -> MemoryConnection {
        guard !app.credentialsLocked else { throw ClientError.server("请先在连接设置解锁已有连接") }
        return MemoryConnection(configuration: app.configuration,username: app.services.adminUsername,password: app.serviceSecrets[.adminPassword] ?? "",chatKey: app.apiKey)
    }
    func database() throws -> ChatStore {
        guard let store = app.store else { throw ClientError.server("本机数据尚未就绪") }; return store
    }
    func report(_ error: any Error) {
        let secrets = [app.apiKey] + Array(app.serviceSecrets.values)
        self.error = JSONValue.string(error.localizedDescription).redacting(secrets).text
    }
    func loadPreferences() async {
        do {
            let store = try database()
            preferences = try await store.records(MemoryFolderPreferences.self,kind: "memory-folders").first ?? MemoryFolderPreferences()
            recovery = try await store.records(MemoryRecoveryPoint.self,kind: "memory-recovery").sorted { $0.createdAt > $1.createdAt }
            drafts = try await store.records(MemoryDraft.self,kind: "memory-draft")
        } catch { report(error) }
    }
    func savePreferences() async {
        do { try await database().put(preferences,kind: "memory-folders",id: "folders") } catch { report(error) }
    }
    func load() async {
        let id = UUID(); revision = id; loading = true; error = nil
        defer { if revision == id { loading = false } }
        do {
            let c = try connection()
            let available = try await client.folders(c.configuration,username: c.username,password: c.password)
            try Task.checkCancellation(); guard revision == id else { return }
            folders = available
            if folder.isEmpty || !available.contains(folder) { folder = visibleFolders.first ?? "" }
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: [RemoteNote]; var output = ""
            if !term.isEmpty && scope == 2 {
                let found = try await tools.semantic(c,query: term); result = found.notes; output = found.output
            } else if !term.isEmpty {
                result = try await client.searchMemory(c,query: term,folder: scope == 0 && !folder.isEmpty ? folder : nil)
            } else if !folder.isEmpty {
                result = try await client.notes(c.configuration,username: c.username,password: c.password,folder: folder)
            } else { result = [] }
            try Task.checkCancellation(); guard revision == id else { return }
            notes = result; semanticOutput = output
        } catch is CancellationError {} catch { if revision == id { report(error) } }
    }
    func read(_ note: RemoteNote) async throws -> MemoryDocument { try await client.memoryDocument(connection(),note: note) }
    func add(_ note: RemoteNote) {
        guard !workbench.contains(where: { $0.id == note.id }) else { return }
        guard workbench.count < 100 else { error = "工作台最多放100篇，请先整理一批"; return }; workbench.append(note)
    }
    func draft(_ note: RemoteNote) async throws -> MemoryDraft {
        let document = try await read(note)
        return MemoryDraft(folder: note.folder,file: note.file,content: document.content,original: document)
    }
    func mergeDraft() async throws -> MemoryDraft {
        guard !workbench.isEmpty else { throw ClientError.server("先把记忆加入工作台") }
        var sections: [String] = [], bytes = 0
        for note in workbench {
            try Task.checkCancellation(); let document = try await read(note); bytes += document.content.utf8.count
            guard bytes <= 2_000_000 else { throw ClientError.server("合并正文超过2MB，请减少篇数") }
            sections.append("## \(note.id)\n\n\(document.content)")
        }
        return MemoryDraft(folder: workbench.first?.folder ?? "",file: "整理-\(Int(Date().timeIntervalSince1970)).txt",content: sections.joined(separator: "\n\n---\n\n"))
    }
    func save(_ draft: MemoryDraft) async throws {
        let c = try connection(),store = try database()
        guard draft.content.utf8.count <= 2_000_000 else { throw ClientError.server("正文超过2MB，请拆分保存") }
        if let original = draft.original { try await client.updateMemory(c,original: original,file: draft.file,content: draft.content,store: store) }
        else { try await client.publishMemory(c,folder: draft.folder,file: draft.file,date: draft.date,author: draft.author,tags: draft.tags,content: draft.content) }
        do { try await store.removeRecord(kind: "memory-draft",id: draft.id) }
        catch { notice = "服务器已保存，但本机旧草稿未能移除；请勿重复发布"; report(error); return }
        drafts.removeAll { $0.id == draft.id }; notice = "已保存到服务器；原始记忆未被合并操作删除"
        await loadPreferences(); await load()
    }
    func keepDraft(_ draft: MemoryDraft) async throws {
        try await database().put(draft,kind: "memory-draft",id: draft.id)
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.append(draft) }
        notice = "草稿已保存在本机"
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true; error = nil
        Task { defer { working = false }; do { try await action() } catch { report(error); await loadPreferences() } }
    }
}

struct MemoryCenterView: View {
    let app: ChatViewModel
    @State private var center: MemoryCenterModel
    @State private var editor: MemoryDraft?
    @State private var workbench = false
    @State private var recovery = false
    @State private var folders = false
    @State private var connecting = false
    @State private var graph: RemoteNote?
    @State private var request = UUID()
    init(model: ChatViewModel) { app = model; _center = State(initialValue: MemoryCenterModel(model)) }
    private var palette: WorkspacePalette { .init(theme: app.appearance.theme) }
    var body: some View {
        List {
            if app.credentialsLocked {
                NavigationLink("解锁已有连接") { ConnectionView(model: app) }.workspaceRowAction()
            }
            Section {
                Picker("检索范围",selection: $center.scope) {
                    Text("当前文件夹").tag(0); Text("全部记忆").tag(1); Text("语义检索").tag(2)
                }
                TextField("搜索记忆",text: $center.query).onSubmit { request = UUID() }
                HStack {
                    Picker("文件夹",selection: $center.folder) {
                        Text("选择文件夹").tag("")
                        ForEach(center.visibleFolders,id: \.self) { Text($0).tag($0) }
                    }
                    Button { folders = true } label: { Image(systemName: "folder.badge.gearshape").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("管理文件夹")
                }
                Button { request = UUID() } label: { Label(center.loading ? "正在读取" : "搜索与刷新",systemImage: "arrow.clockwise") }.workspaceRowAction()
            }
            if let error = center.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !center.notice.isEmpty { Text(center.notice).font(.callout).foregroundStyle(.secondary) }
            Section {
                ForEach(center.notes) { note in
                    HStack(spacing: 12) {
                        Button { center.perform { editor = try await center.draft(note) } } label: { MemoryNoteLabel(note: note) }.buttonStyle(.plain)
                        Button { center.add(note) } label: { Image(systemName: center.workbench.contains(where: { $0.id == note.id }) ? "checkmark.circle.fill" : "plus.circle").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("加入工作台：\(note.file)")
                    }.contextMenu {
                        Button("打开记忆") { center.perform { editor = try await center.draft(note) } }
                        Button("加入工作台") { center.add(note) }
                        Button("联想图谱") { graph = note }
                    }
                }
                if center.notes.isEmpty && !center.loading { Text("暂无记忆；选择文件夹，或输入关键词搜索").foregroundStyle(.secondary) }
                if !center.semanticOutput.isEmpty {
                    DisclosureGroup("语义检索原始结果") { Text(center.semanticOutput).font(.callout).textSelection(.enabled) }
                }
            } header: { Text("\(center.notes.count) 篇记忆") }
            if !center.drafts.isEmpty {
                Section("本机草稿") {
                    ForEach(center.drafts) { draft in Button(draft.file.isEmpty ? "未命名草稿" : draft.file) { editor = draft }.workspaceRowAction() }
                }
            }
            Section {
                Button("整理工作台 · \(center.workbench.count) 篇") { workbench = true }.workspaceRowAction()
                Button("修改前备份与恢复") { recovery = true }.workspaceRowAction()
                Button("记忆服务连接") { connecting = true }.workspaceRowAction()
            } footer: { Text("浏览、编辑和图谱使用服务器日记接口；语义检索使用原版 LightMemo。工作台整理先生成可编辑的新记忆，保留来源原文。") }
        }.listStyle(.inset).scrollContentBackground(.hidden).navigationTitle("记忆中心")
        .background(ThemeWallpaper(app.appearance,animations: app.renderOptions.motion).ignoresSafeArea())
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { editor = MemoryDraft(folder: center.folder) } label: { Label("新记忆",systemImage: "square.and.pencil").frame(minHeight: 44).contentShape(Rectangle()) } } }
        .disabled(center.working)
        .overlay(alignment: .top) { if center.loading || center.working { ProgressView().padding(12).background(.regularMaterial,in: Capsule()) } }
        .task(id: request) { await center.loadPreferences(); await center.load() }
        .onChange(of: center.folder) { _,_ in request = UUID() }
        .onChange(of: center.scope) { _,_ in request = UUID() }
        .sheet(item: $editor) { draft in MemoryEditor(center: center,initial: draft) }
        .sheet(isPresented: $workbench) { NavigationStack { MemoryWorkbench(center: center) } }
        .sheet(isPresented: $recovery) { NavigationStack { MemoryRecoveryView(center: center) } }
        .sheet(isPresented: $folders) { NavigationStack { MemoryFoldersView(center: center) } }
        .sheet(isPresented: $connecting,onDismiss: { request = UUID() }) { NavigationStack { MemoryConnectionView(center: center) } }
        .sheet(item: $graph) { note in NavigationStack { MemoryGraphView(center: center,root: note) } }
        .tint(palette.accent)
    }
}

private struct MemoryNoteLabel: View {
    let note: RemoteNote
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            Text(note.file).font(.headline).lineLimit(2)
            Text(note.folder).font(.caption).foregroundStyle(.secondary)
            if !note.preview.isEmpty { Text(note.preview).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
        }.frame(maxWidth: .infinity,alignment: .leading).frame(minHeight: 44).padding(.vertical,6).contentShape(Rectangle())
    }
}

private struct MemoryConnectionView: View {
    @Bindable var center: MemoryCenterModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            if center.app.credentialsLocked { NavigationLink("解锁连接密钥") { ConnectionView(model: center.app) }.workspaceRowAction() }
            LabeledContent("服务器",value: center.app.configuration.server)
            TextField("日记管理员用户名",text: Binding(get: { center.app.services.adminUsername },set: { center.app.services.adminUsername = $0 }))
            SecureField("日记管理员密码",text: Binding(get: { center.app.serviceSecrets[.adminPassword] ?? "" },set: { center.app.serviceSecrets[.adminPassword] = $0 }))
            Text("日记接口使用管理员连接；语义检索另用现有聊天 API Key。只有你主动解锁后才读取钥匙串。").font(.callout).foregroundStyle(.secondary)
            if let error = center.error { Text(error).foregroundStyle(.red) }
            Button("保存连接") { center.perform { guard await center.app.saveServices() else { throw ClientError.server(center.app.error ?? "连接保存失败") }; dismiss() } }.workspaceRowAction().disabled(center.working)
        }.navigationTitle("记忆服务连接").toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("关闭").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) } } }
    }
}

private struct MemoryEditor: View {
    let center: MemoryCenterModel
    let initial: MemoryDraft
    @State private var draft: MemoryDraft
    @State private var preview = false
    @State private var busy = false
    @State private var error: String?
    @State private var closing = false
    @State private var graph = false
    @Environment(\.dismiss) private var dismiss
    init(center: MemoryCenterModel,initial: MemoryDraft) { self.center = center; self.initial = initial; _draft = State(initialValue: initial) }
    private var palette: WorkspacePalette { .init(theme: center.app.appearance.theme) }
    private var dirty: Bool { draft.folder != initial.folder || draft.file != initial.file || draft.content != initial.content || draft.date != initial.date || draft.tags != initial.tags || draft.author != initial.author }
    var body: some View {
        WorkspacePanel(title: draft.original == nil ? "新记忆" : "编辑记忆",palette: palette,close: close) {
            VStack(alignment: .leading,spacing: 18) {
                WorkspaceField(title: "文件夹",palette: palette) { TextField("文件夹名称",text: $draft.folder).disabled(draft.original != nil) }
                WorkspaceField(title: "文件名",palette: palette) { TextField("文件名.txt",text: $draft.file) }
                if draft.original == nil {
                    DatePicker("日期",selection: $draft.date,displayedComponents: .date)
                    WorkspaceField(title: "作者／Agent（可选）",palette: palette) { TextField("留空使用文件夹名称",text: $draft.author) }
                    WorkspaceField(title: "标签（可选）",palette: palette) { TextField("沿用 DailyNote 的标签格式",text: $draft.tags) }
                }
                Toggle("渲染预览",isOn: $preview)
                if preview { RichMessageBody(draft.content,options: center.app.renderOptions).frame(maxWidth: .infinity,alignment: .leading) }
                else { TextEditor(text: $draft.content).scrollContentBackground(.hidden).frame(minHeight: 320).accessibilityLabel("记忆原文") }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let original = draft.original {
                    Button("加入整理工作台") { center.add(original.note) }.workspaceAction(palette)
                    Button("打开联想图谱") { graph = true }.workspaceAction(palette)
                }
                Text("编辑已有记忆前检查服务器原文，并保存本机备份；新建或改名遇到重名时不覆盖。保存失败会保留当前草稿。").font(.caption).foregroundStyle(palette.muted)
            }.disabled(busy)
        } footer: {
            HStack {
                Button("存为草稿") { run { try await center.keepDraft(draft); dismiss() } }.workspaceAction(palette).disabled(busy)
                Button(busy ? "保存中…" : "保存到服务器") { run { try await center.save(draft); dismiss() } }.workspaceAction(palette,primary: true).disabled(busy || draft.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.frame(minWidth: 320,minHeight: 480).interactiveDismissDisabled(busy || dirty)
        .confirmationDialog("保留未保存的修改？",isPresented: $closing,titleVisibility: .visible) {
            Button("保存本机草稿并关闭") { run { try await center.keepDraft(draft); dismiss() } }
            Button("放弃这次修改",role: .destructive) { dismiss() }
            Button("继续编辑",role: .cancel) {}
        }
        .sheet(isPresented: $graph) { if let original = draft.original { NavigationStack { MemoryGraphView(center: center,root: original.note) } } }
    }
    private func close() { guard !busy else { return }; if dirty { closing = true } else { dismiss() } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { center.report(error); self.error = center.error } }
    }
}

private struct MemoryWorkbench: View {
    @Bindable var center: MemoryCenterModel
    @State private var editor: MemoryDraft?
    @State private var target = ""
    @State private var deleting = false
    @State private var moving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("来源记忆 · \(center.workbench.count) 篇") {
                ForEach(center.workbench) { note in
                    Button { center.perform { editor = try await center.draft(note) } } label: { MemoryNoteLabel(note: note) }.buttonStyle(.plain)
                }.onDelete { offsets in center.workbench.remove(atOffsets: offsets) }
            }
            Section {
                Button("全文合并为新草稿") { center.perform { editor = try await center.mergeDraft() } }.workspaceRowAction().disabled(center.workbench.isEmpty)
                Text("合并只创建新记忆，不删除或移动来源。编辑确认后再发布；左滑仅从工作台移除。").font(.callout).foregroundStyle(.secondary)
            }
            Section("批量整理") {
                TextField("目标文件夹，如“已整理”",text: $target)
                Button("移动所选记忆") { moving = true }.workspaceRowAction().disabled(center.workbench.isEmpty || target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("归档到“已整理”") { target = "已整理"; moving = true }.workspaceRowAction().disabled(center.workbench.isEmpty)
                Button("删除所选服务器记忆",role: .destructive) { deleting = true }.workspaceRowAction().disabled(center.workbench.isEmpty)
                Text("修改前在本机逐篇保留原文；目标有同名文件时停止，不覆盖。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = center.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("整理工作台").disabled(center.working).interactiveDismissDisabled(center.working)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("关闭").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) }.disabled(center.working) } }
        .sheet(item: $editor) { MemoryEditor(center: center,initial: $0) }
        .confirmationDialog("删除工作台内\(center.workbench.count)篇服务器记忆？",isPresented: $deleting,titleVisibility: .visible) {
            Button("备份后删除",role: .destructive) { center.perform { try await center.client.deleteMemories(center.connection(),notes: center.workbench,store: center.database()); center.workbench = []; await center.loadPreferences(); await center.load() } }
        } message: { Text("服务器原文件会被删除。本机备份可恢复缺失文件，不覆盖当前已有内容。") }
        .confirmationDialog("移动到“\(target)”？",isPresented: $moving,titleVisibility: .visible) {
            Button("备份后移动") { center.perform { try await center.client.moveMemories(center.connection(),notes: center.workbench,target: target,store: center.database()); center.workbench = []; await center.loadPreferences(); await center.load() } }
        }
    }
}

private struct MemoryFoldersView: View {
    @Bindable var center: MemoryCenterModel
    @State private var deleting: String?
    @Environment(\.dismiss) private var dismiss
    private var ordered: [String] { center.preferences.order.filter { center.folders.contains($0) } + center.folders.filter { !center.preferences.order.contains($0) }.sorted() }
    var body: some View {
        List {
            Section {
                ForEach(ordered,id: \.self) { folder in
                    HStack {
                        Toggle(folder,isOn: Binding(get: { !center.preferences.hidden.contains(folder) },set: { on in if on { center.preferences.hidden.remove(folder) } else { center.preferences.hidden.insert(folder) }; Task { await center.savePreferences() } }))
                        Button(role: .destructive) { deleting = folder } label: { Image(systemName: "trash").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.borderless).accessibilityLabel("删除空文件夹：\(folder)")
                    }
                }.onMove { indices,destination in var value = ordered; value.move(fromOffsets: indices,toOffset: destination); center.preferences.order = value; Task { await center.savePreferences() } }
            } footer: { Text("开关仅隐藏本机文件夹入口，不影响全局检索或服务器文件。拖动调整顺序。新记忆中填写新的文件夹名称即可创建。只允许删除服务器空文件夹。") }
            if let error = center.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("文件夹").disabled(center.working).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("关闭").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) } }
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) { EditButton() }
            #endif
        }.confirmationDialog("删除空文件夹？",isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),titleVisibility: .visible,presenting: deleting) { folder in
            Button("删除“\(folder)”",role: .destructive) { center.perform { try await center.client.deleteMemoryFolder(center.connection(),folder: folder); await center.load() } }
        }
    }
}

private struct MemoryRecoveryView: View {
    @Bindable var center: MemoryCenterModel
    @State private var restoring: MemoryRecoveryPoint?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section { Text("备份保存在本机。恢复只补回缺失文件；已存在且内容不同的文件不会覆盖。移动后的目标文件也不会被删除。").font(.callout).foregroundStyle(.secondary) }
            ForEach(center.recovery) { point in
                Section {
                    ForEach(point.documents) { document in
                        NavigationLink(document.note.id) { NativeFileText(text: document.content).navigationTitle(document.note.file).toolbar { ShareLink(item: document.content) { Label("导出原文",systemImage: "square.and.arrow.up").frame(minHeight: 44).contentShape(Rectangle()) } } }.workspaceRowAction()
                    }
                    Button("恢复缺失文件（不覆盖）") { restoring = point }.workspaceRowAction()
                } header: { Text("\(point.operation) · \(Date(timeIntervalSince1970: point.createdAt).formatted())") }
            }
            if center.recovery.isEmpty { Text("暂时没有修改备份") }
            if let error = center.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("记忆恢复").disabled(center.working).interactiveDismissDisabled(center.working)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("关闭").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) }.disabled(center.working) } }
        .confirmationDialog("补回本次备份中缺失的文件？",isPresented: Binding(get: { restoring != nil },set: { if !$0 { restoring = nil } }),titleVisibility: .visible,presenting: restoring) { point in
            Button("恢复缺失文件") { center.perform { try await center.client.restoreMemories(center.connection(),point: point); center.notice = "缺失文件已恢复；已有文件保持不变"; await center.load() } }
        }
    }
}

private struct MemoryGraphView: View {
    let center: MemoryCenterModel
    let root: RemoteNote
    @State private var nodes: [RemoteNote] = []
    @State private var edges: Set<MemoryEdge> = []
    @State private var associations: [String:MemoryAssociation] = [:]
    @State private var selected: RemoteNote?
    @State private var editor: MemoryDraft?
    @State private var k = 10
    @State private var boost = "0.6+"
    @State private var ranges: Set<String> = []
    @State private var configuring = false
    @State private var busy = false
    @State private var error: String?
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup("联想范围与参数",isExpanded: $configuring) {
                Stepper("每次联想 \(k) 篇",value: $k,in: 1...30)
                TextField("标签增强，如0.6+",text: $boost)
                ScrollView(.horizontal) { HStack {
                    ForEach(center.folders,id: \.self) { folder in
                        Button { if ranges.contains(folder) { ranges.remove(folder) } else { ranges.insert(folder) } } label: { Label(folder,systemImage: ranges.contains(folder) ? "checkmark.circle.fill" : "circle").padding(8).contentShape(Rectangle()) }.buttonStyle(.bordered)
                    }
                } }
                Text("未选择范围时只联想当前节点所在文件夹；更改参数后点“展开联想”。").font(.caption).foregroundStyle(.secondary)
            }.padding().disabled(busy)
            GeometryReader { geometry in
                ZStack {
                    Canvas { context,size in
                        for edge in edges {
                            guard let from = nodes.firstIndex(where: { $0.id == edge.from }),let to = nodes.firstIndex(where: { $0.id == edge.to }) else { continue }
                            var path = Path(); path.move(to: position(from,size)); path.addLine(to: position(to,size)); context.stroke(path,with: .color(.secondary.opacity(0.4)),lineWidth: 1)
                        }
                    }
                    ForEach(Array(nodes.enumerated()),id: \.element.id) { index,note in
                        Button { selected = note } label: {
                            VStack(spacing: 4) { Image(systemName: index == 0 ? "brain.head.profile" : "doc.text"); Text(note.file).font(.caption).lineLimit(2) }
                                .frame(width: 92,height: 70).padding(8).background(selected?.id == note.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),in: RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
                        }.buttonStyle(.plain).position(position(index,geometry.size))
                    }
                }.scaleEffect(min(3,max(0.4,zoom * magnification))).offset(x: pan.width + drag.width,y: pan.height + drag.height)
                    .gesture(DragGesture().updating($drag) { value,state,_ in state = value.translation }.onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height })
                    .simultaneousGesture(MagnifyGesture().updating($magnification) { value,state,_ in state = value.magnification }.onEnded { zoom = min(3,max(0.4,zoom * $0.magnification)) })
            }.frame(minHeight: 250).clipped().background(Color.secondary.opacity(0.08))
            if let selected {
                VStack(alignment: .leading,spacing: 10) {
                    Text(selected.id).font(.headline).lineLimit(2)
                    if let link = associations[selected.id] {
                        Text("相关性 \(link.score.formatted(.number.precision(.fractionLength(3)))) · \(link.tags.joined(separator: "、"))").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("展开联想") { expand(selected) }.buttonStyle(.borderedProminent)
                        Button("阅读全文") { center.perform { editor = try await center.draft(selected) } }.buttonStyle(.bordered)
                        Button("加入工作台") { center.add(selected) }.buttonStyle(.bordered)
                    }.controlSize(.regular).disabled(busy || center.working)
                }.padding()
            }
            if busy { ProgressView("正在读取联想关系").padding(8) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding() }
        }.navigationTitle("记忆联想图谱").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Text("关闭").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) } }
            ToolbarItem(placement: .primaryAction) { Button { zoom = 1; pan = .zero } label: { Text("复位视图").frame(minWidth: 44,minHeight: 44).contentShape(Rectangle()) } }
        }.task { nodes = [root]; selected = root; expand(root) }
        .sheet(item: $editor) { MemoryEditor(center: center,initial: $0) }
    }
    private func position(_ index: Int,_ size: CGSize) -> CGPoint {
        let middle = CGPoint(x: size.width / 2,y: size.height / 2)
        guard index > 0 else { return middle }
        let ring = (index - 1) / 12 + 1, slot = (index - 1) % 12
        let angle = Double(slot) * .pi / 6 - .pi / 2
        let radius = Double(ring) * 150
        return CGPoint(x: middle.x + cos(angle) * radius,y: middle.y + sin(angle) * radius)
    }
    private func expand(_ note: RemoteNote) {
        guard !busy else { return }; busy = true; error = nil
        let count = k,folders = Array(ranges),tagBoost = boost
        Task { defer { busy = false }; do {
            let found = try await center.client.associations(center.connection(),note: note,k: count,folders: folders,tagBoost: tagBoost)
            for link in found where link.id != note.id {
                if !nodes.contains(where: { $0.id == link.id }) {
                    guard nodes.count < 200 else { error = "图谱已达到200个节点；可换一个来源继续浏览"; break }; nodes.append(link.note)
                }
                edges.insert(MemoryEdge(from: note.id,to: link.id)); associations[link.id] = link
            }
            if found.isEmpty { error = "此范围内暂未找到关联记忆" }
        } catch { center.report(error); self.error = center.error } }
    }
}
