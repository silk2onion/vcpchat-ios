import SwiftUI
import VChatCore

struct NotesView: View {
    let model: ChatViewModel
    @State private var remote = false
    @State private var notes: [LocalNote] = []
    @State private var removed = false
    @State private var query = ""
    @State private var editing: LocalNote?
    @State private var error: String?
    var body: some View {
        List {
            Section { NavigationLink { RemoteNotesView(model: model) } label: { Label("服务器日记",systemImage: "network") } }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                Button("新笔记",systemImage: "square.and.pencil") { editing = LocalNote() }
                Toggle("查看已删除笔记",isOn: $removed)
            }
            ForEach(notes.filter { query.isEmpty || ($0.title + $0.body).localizedCaseInsensitiveContains(query) }) { note in
                Button { editing = note } label: { VStack(alignment: .leading,spacing: 5) { Text(note.title).font(.headline).foregroundStyle(.primary); Text(note.body.isEmpty ? "空白" : note.body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.padding(.vertical,5) }.buttonStyle(.plain)
            }
            if notes.isEmpty { ContentUnavailableView(removed ? "没有已删除笔记" : "记下一个想法",systemImage: "note.text") }
        }.navigationTitle("笔记").searchable(text: $query,prompt: "搜索本机笔记")
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
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("标题",text: $note.title).font(.title2).padding(.horizontal)
                TextEditor(text: $note.body).font(.body).padding(.horizontal)
                if let error { Text(error).foregroundStyle(.red) }
                Button(removed ? "恢复笔记" : "移到已删除笔记",systemImage: removed ? "arrow.uturn.backward" : "trash") { Task { do { try await model.store?.trashNote(note,restoring: removed); dismiss() } catch { self.error = error.localizedDescription } } }.padding(.bottom)
            }.disabled(removed).overlay(alignment: .bottom) { if removed { Button("恢复笔记") { Task { do { try await model.store?.trashNote(note,restoring: true); dismiss() } catch { self.error = error.localizedDescription } } }.padding() } }
            .navigationTitle(removed ? "已删除笔记" : "本机笔记").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { do { note.updatedAt = Date().timeIntervalSince1970; if note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { note.title = "未命名笔记" }; try await model.store?.saveNote(note); dismiss() } catch { self.error = error.localizedDescription } } }.disabled(removed) }
            }
        }.frame(minWidth: 360,minHeight: 480)
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
                Button("保存连接") { work { if !(await model.saveServices()) { throw ClientError.server(model.error ?? "保存失败") }; notice = "连接已保存" } }
            }
            Button("刷新文件夹",systemImage: "arrow.clockwise") { work { folders = try await client.folders(model.configuration,username: model.services.adminUsername,password: password); if folder.isEmpty { folder = folders.first ?? "" }; try await list() } }.disabled(busy)
            Picker("文件夹",selection: $folder) { Text("选择文件夹").tag(""); ForEach(folders,id: \.self) { Text($0).tag($0) } }.onChange(of: folder) { _, _ in work { try await list() } }
            TextField("搜索服务器日记",text: $query).onSubmit { work { try await list() } }
            Button("搜索",systemImage: "magnifyingglass") { work { try await list() } }.disabled(busy || folder.isEmpty)
            Button("新日记",systemImage: "square.and.pencil") { file = ""; bodyText = ""; editing = true }.disabled(folder.isEmpty)
            ForEach(notes) { note in Button { work { bodyText = try await client.read(model.configuration,username: model.services.adminUsername,password: password,folder: note.folder,file: note.file); folder = note.folder; file = note.file; editing = true } } label: { VStack(alignment: .leading,spacing: 5) { Text(note.file); Text(note.preview.isEmpty ? note.lastModified : note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2) } }.disabled(busy) }
        }.navigationTitle("服务器日记").overlay { if busy { ProgressView().padding(20).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12)) } }
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
