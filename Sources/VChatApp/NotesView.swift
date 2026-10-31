import SwiftUI
import VChatCore
import VChatRendering

struct NotesView: View {
    let model: ChatViewModel
    @Binding var searching: Bool
    @State private var mode = 0
    @State private var remote = false
    @State private var notes: [LocalNote] = []
    @State private var removed = false
    @State private var query = ""
    @State private var editing: LocalNote?
    @State private var error: String?
    init(model: ChatViewModel,searching: Binding<Bool> = .constant(false)) { self.model = model; _searching = searching }
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var visibleNotes: [LocalNote] { notes.filter { query.isEmpty || ($0.title + $0.body).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSegments(titles: ["本机","服务器日记"],selection: $mode,palette: palette).padding(.horizontal,20).padding(.vertical,12)
            if mode == 1 { RemoteNotesView(model: model).onDisappear { Task { await refresh() } } }
            else { ScrollView {
                LazyVStack(alignment: .leading,spacing: 16) {
                    Button("新笔记") { editing = LocalNote() }.workspaceAction(palette,primary: true)
                    WorkspaceSearch(query: $query,showing: $searching,prompt: "搜索本机笔记",palette: palette)
                    Toggle("查看已删除笔记",isOn: $removed).font(.system(size: 13)).foregroundStyle(palette.muted).toggleStyle(.switch)
                    if let error { Text(error).foregroundStyle(.red) }
                    ForEach(visibleNotes) { note in
                        Button { editing = note } label: { VStack(alignment: .leading,spacing: 8) { Text(note.title).font(.system(size: 16,weight: .semibold)).foregroundStyle(palette.ink); Text(note.body.isEmpty ? "空白" : String(note.body.prefix(180))).font(.system(size: 14)).foregroundStyle(palette.muted).lineLimit(2) }.padding(16).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.workspaceGlass(palette)
                    }
                    if !query.isEmpty && visibleNotes.isEmpty { ContentUnavailableView("没有匹配的笔记",systemImage: "magnifyingglass") }
                    else if notes.isEmpty { VStack(spacing: 12) { Text(removed ? "没有已删除笔记" : "从一条本地笔记开始").font(.system(size: 19,weight: .semibold)); Text("本机笔记不会自动上传到服务器。").font(.system(size: 14)).foregroundStyle(palette.muted) }.frame(maxWidth: .infinity).padding(.vertical,90) }
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively) }
        }.navigationTitle("笔记").buttonStyle(WorkspacePress()).foregroundStyle(palette.ink).background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .task { await refresh() }.onChange(of: removed) { _, _ in Task { await refresh() } }
        .sheet(item: $editing,onDismiss: { Task { await refresh() } }) { NoteEditor(model: model,note: $0,removed: removed) }
    }
    func refresh() async { do { notes = try await model.store?.records(LocalNote.self,kind: removed ? "note-trash" : "note") ?? [] } catch { self.error = error.localizedDescription } }
}
private struct NoteEditor: View {
    let model: ChatViewModel
    @State var note: LocalNote
    var removed: Bool
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        WorkspacePanel(title: removed ? "已删除笔记" : "本机笔记",palette: palette,close: { dismiss() }) {
            VStack(alignment: .leading,spacing: 20) {
                WorkspaceField(title: "标题",palette: palette) { TextField("标题",text: $note.title).disabled(removed) }
                WorkspaceField(title: "正文",palette: palette) { TextEditor(text: $note.body).scrollContentBackground(.hidden).frame(minHeight: 300).disabled(removed).accessibilityLabel("笔记正文") }
                if let error { Text(error).foregroundStyle(.red) }
                Button(removed ? "恢复笔记" : "移到已删除笔记",systemImage: removed ? "arrow.uturn.backward" : "trash") { Task { do { try await model.store?.trashNote(note,restoring: removed); dismiss() } catch { self.error = error.localizedDescription } } }.foregroundStyle(removed ? palette.accent : .red)
            }
        } footer: { HStack(spacing: 10) {
            Button("取消") { dismiss() }.workspaceAction(palette)
            Button("保存") { Task { do { note.updatedAt = Date().timeIntervalSince1970; if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note.title = "未命名笔记" }; try await model.store?.saveNote(note); dismiss() } catch { self.error = error.localizedDescription } } }.workspaceAction(palette,primary: true).disabled(removed)
        } }.frame(minWidth: 360,minHeight: 480)
    }

}
struct RemoteNotesView: View {
    @Bindable var model: ChatViewModel
    @State private var client = DailyNotesClient()
    @State private var folders: [String] = []
    @State private var folder = ""
    @State private var notes: [RemoteNote] = []
    @State private var query = ""
    @State private var file = ""
    @State private var bodyText = ""
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice = ""
    var password: String { model.serviceSecrets[.adminPassword] ?? "" }
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            DisclosureGroup("日记管理员连接") {
                TextField("用户名",text: $model.services.adminUsername)
                SecureField("管理员密码",text: Binding(get: { password },set: { model.serviceSecrets[.adminPassword] = $0 }))
                Button { work { if !(await model.saveServices()) { throw ClientError.server(model.error ?? "保存失败") }; notice = "连接已保存" } } label: { Text("保存连接").frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
            }
            Button { work { folders = try await client.folders(model.configuration,username: model.services.adminUsername,password: password); if folder.isEmpty { folder = folders.first ?? "" }; try await list() } } label: { Label("刷新文件夹",systemImage: "arrow.clockwise").frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(busy)
            Picker("文件夹",selection: $folder) { Text("选择文件夹").tag(""); ForEach(folders,id: \.self) { Text($0).tag($0) } }.onChange(of: folder) { _, _ in work { try await list() } }
            TextField("搜索服务器日记",text: $query).onSubmit { work { try await list() } }
            Button { work { try await list() } } label: { Label("搜索",systemImage: "magnifyingglass").frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(busy || folder.isEmpty)
            Button { file = ""; bodyText = ""; editing = true } label: { Label("新日记",systemImage: "square.and.pencil").frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(folder.isEmpty)
            ForEach(notes) { note in
                Button {
                    work { bodyText = try await client.read(model.configuration,username: model.services.adminUsername,password: password,folder: note.folder,file: note.file); folder = note.folder; file = note.file; editing = true }
                } label: {
                    VStack(alignment: .leading,spacing: 5) {
                        Text(note.file)
                        Text(note.preview.isEmpty ? note.lastModified : note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy)
            }
        }.scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("服务器日记").overlay { if busy { ProgressView().padding(20).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12)) } }
        .sheet(isPresented: $editing) {
            NavigationStack { VStack { TextField("文件名",text: $file).padding(); TextEditor(text: $bodyText).padding(.horizontal); if let error { Text(error).foregroundStyle(.red) } }.navigationTitle(folder).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }; ToolbarItem(placement: .confirmationAction) { Button("保存到服务器") { work {
                        // Retain the remote pre-edit body locally before replacing it.
                        let filename = try NotePath.filename(file)
                        do { let before = try await client.read(model.configuration,username: model.services.adminUsername,password: password,folder: folder,file: filename); var backup = LocalNote(); backup.title = "日记备份 · \(folder)/\(filename)"; backup.body = before; try await model.store?.saveNote(backup) } catch ClientError.http(404) { /* New file; nothing to back up. */ }
                        try await client.save(model.configuration,username: model.services.adminUsername,password: password,folder: folder,file: filename,content: bodyText); editing = false; notice = "日记已保存"; try await list()
                    } }.disabled(busy || file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } } }.frame(minWidth: 360,minHeight: 480)
        }
    }
    func list() async throws { guard !folder.isEmpty else { return }; notes = try await client.notes(model.configuration,username: model.services.adminUsername,password: password,folder: folder,query: query) }
    func work(_ action: @escaping @MainActor () async throws -> Void) { guard !busy else { return }; busy = true; error = nil; Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } } }
}
