import SwiftUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering
private struct FolderItem: Identifiable { var value: JSONValue; var id: String { value["id"].text }; var name: String { value["name"].text } }
struct ConnectedFoldersView: View {
    let model: ChatViewModel
    @State private var folders: [FolderItem] = []
    @State private var selecting = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            Section { NavigationLink { FileNodeView(model: model) } label: { Label("移动版 FileOperator",systemImage: "point.3.connected.trianglepath.dotted") } }
            Section { Button("连接文件夹…",systemImage: "folder.badge.plus") { selecting = true }; Text("通过系统选择器连接一个工作文件夹。App 可直接读写，修改前保留备份；Agent 默认没有权限。").font(.caption).foregroundStyle(.secondary) }
            ForEach(folders) { folder in NavigationLink { ConnectedFolderBrowser(model: model,folderID: folder.id,name: folder.name) } label: { Label(folder.name,systemImage: "folder") } }
            if folders.isEmpty { ContentUnavailableView("尚未连接文件夹",systemImage: "folder.badge.plus") }
        }.navigationTitle("连接文件夹").task { await refresh() }
        .fileImporter(isPresented: $selecting,allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { do { guard let engine = model.connectedFolders else { throw ClientError.server("本机文件引擎尚未就绪") }; _ = try await engine.connect(url); await refresh() } catch { self.error = error.localizedDescription } } }
        }
    }
    func refresh() async { do { let value = try await model.connectedFolders?.request(.object(["action": .string("folders")])); folders = value?.array.map { FolderItem(value: $0) } ?? [] } catch { self.error = error.localizedDescription } }
}
private struct ConnectedEntry: Identifiable { var value: JSONValue; var id: String { value["path"].text }; var name: String { value["name"].text }; var directory: Bool { value["type"].text == "directory" } }
private struct ConnectedEdit: Identifiable { var id = UUID(); var document: ConnectedDocument }
struct ConnectedFolderBrowser: View {
    let model: ChatViewModel; let folderID: String; let name: String
    var path = ""
    @State private var entries: [ConnectedEntry] = []
    @State private var error: String?
    @State private var truncated = false
    @State private var document: ConnectedEdit?
    @State private var prompt = false
    @State private var operation = ""
    @State private var source = ""
    @State private var version = ""
    @State private var destination = ""
    @State private var permission = "off"
    @State private var currentAccess = "off"
    @State private var granting = false
    @State private var deleting: ConnectedEntry?
    @Environment(\.dismiss) private var dismiss
    var engine: ConnectedFolders? { model.connectedFolders }
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if path.isEmpty { Section {
                Menu("Agent 权限：" + (currentAccess == "write" ? "可读写" : currentAccess == "read" ? "只读" : "未授权")) { Button("不授权") { grant("off") }; Button("只读") { permission = "read"; granting = true }; Button("可读写（保留备份）") { permission = "write"; granting = true } }
                NavigationLink { ConnectedBackupsView(model: model,folderID: folderID) } label: { Label("修改备份与恢复",systemImage: "clock.arrow.circlepath") }
                Button("断开此文件夹",role: .destructive) { Task { do { _ = try await engine?.request(.object(["action": .string("disconnect"),"folderId": .string(folderID)])); dismiss() } catch { self.error = error.localizedDescription } } }
            } }
            if truncated { Label("条目超过 2000 个，仅列出前 2000 项",systemImage: "info.circle").font(.caption) }
            ForEach(entries) { entry in
                HStack {
                    if entry.directory { NavigationLink { ConnectedFolderBrowser(model: model,folderID: folderID,name: name,path: entry.id) } label: { Label(entry.name,systemImage: "folder") } }
                    else { Button { open(entry) } label: { Label(entry.name,systemImage: entry.value["type"].text == "symlink" ? "link" : "doc").frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).disabled(entry.value["type"].text == "symlink") }
                    Menu { Button("改名") { modify("RenameFile",entry: entry) }; Button("复制到…") { modify("CopyFile",entry: entry) }; Button("移动到…") { modify("MoveFile",entry: entry) }; Button("删除（保留备份）",role: .destructive) { deleting = entry } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
        }.navigationTitle(path.isEmpty ? name : (path as NSString).lastPathComponent)
        .toolbar { Menu { Button("新文本文件") { operation = "WriteFile"; destination = ""; prompt = true }; Button("新文件夹") { operation = "CreateDirectory"; destination = ""; prompt = true }; Button("刷新") { Task { await refresh() } } } label: { Image(systemName: "plus") } }
        .task { await refresh() }
        .sheet(item: $document,onDismiss: { Task { await refresh() } }) { ConnectedDocumentEditor(model: model,folderID: folderID,document: $0.document) }
        .sheet(isPresented: $prompt) { NavigationStack { Form { TextField(operation == "WriteFile" || operation == "CreateDirectory" ? "名称" : "目标相对路径",text: $destination); if let error { Text(error).foregroundStyle(.red) } }.navigationTitle(operation == "WriteFile" ? "新文本文件" : operation == "CreateDirectory" ? "新文件夹" : "目标位置").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { prompt = false } }; ToolbarItem(placement: .confirmationAction) { Button("确认") { Task { await apply() } }.disabled(destination.isEmpty) } } }.frame(minWidth: 350,minHeight: 250) }
        .confirmationDialog("授权 Agent \(permission == "write" ? "读写" : "读取")“\(name)”？只有此文件夹内的相对路径可用，修改前保留备份。",isPresented: $granting,titleVisibility: .visible) { Button("确认授权") { grant(permission) } }
        .confirmationDialog("删除“\(deleting?.name ?? "")”？删除前会保留可恢复的备份。",isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),titleVisibility: .visible) { Button("删除并保留备份",role: .destructive) { if let item = deleting { Task { do { let info = try await engine?.execute(folderID: folderID,args: ["command": .string("FileInfo"),"filePath": .string(item.id)]); _ = try await engine?.execute(folderID: folderID,args: ["command": .string("DeleteFile"),"filePath": .string(item.id),"expectedVersion": info?["version"] ?? .null]); await refresh() } catch { self.error = error.localizedDescription }; deleting = nil } } } }
    }
    func refresh() async { do { let folders = try await engine?.request(.object(["action": .string("folders")])); currentAccess = folders?.array.first { $0["id"].text == folderID }?["agentAccess"].text ?? "off"; let value = try await engine?.execute(folderID: folderID,args: ["command": .string("ListDirectory"),"directoryPath": .string(path)]); entries = value?["items"].array.map { ConnectedEntry(value: $0) }.sorted { $0.directory != $1.directory ? $0.directory : $0.name.localizedStandardCompare($1.name) == .orderedAscending } ?? []; truncated = value?["truncated"].bool == true } catch { self.error = error.localizedDescription } }
    private func open(_ entry: ConnectedEntry) { Task { do { guard let doc = try await engine?.read(folderID: folderID,path: entry.id) else { throw ClientError.server("文件引擎未就绪") }; document = ConnectedEdit(document: doc) } catch { self.error = error.localizedDescription } } }
    func grant(_ access: String) { Task { do { _ = try await engine?.request(.object(["action": .string("grant"),"folderId": .string(folderID),"access": .string(access)])); currentAccess = access; error = nil } catch { self.error = error.localizedDescription } } }
    private func modify(_ command: String,entry: ConnectedEntry) { Task { do { let info = try await engine?.execute(folderID: folderID,args: ["command": .string("FileInfo"),"filePath": .string(entry.id)]); source = entry.id; version = info?["version"].text ?? ""; operation = command; destination = entry.id; error = nil; prompt = true } catch { self.error = error.localizedDescription } } }
    func apply() async {
        do {
            var args: [String: JSONValue] = ["command": .string(operation)]
            if operation == "WriteFile" || operation == "CreateDirectory" { let leaf = try NotePath.segment(destination); let relative = path.isEmpty ? leaf : path + "/" + leaf; args[operation == "WriteFile" ? "filePath" : "directoryPath"] = .string(relative); if operation == "WriteFile" { args["content"] = .string("") } }
            else { args["sourcePath"] = .string(source); args["destinationPath"] = .string(destination); args["expectedVersion"] = .string(version) }
            _ = try await engine?.execute(folderID: folderID,args: args); prompt = false; error = nil; await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
struct ConnectedDocumentEditor: View {
    let model: ChatViewModel; let folderID: String
    @State var document: ConnectedDocument
    @State private var text = ""
    @State private var image = ""
    @State private var exporting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var mime: String { UTType(filenameExtension: (document.path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream" }
    var body: some View {
        NavigationStack { VStack {
            if document.text != nil { TextEditor(text: $text).font(.body).padding() }
            else if !image.isEmpty { NativeRaster(image,fill: false) }
            else { ContentUnavailableView("可导出原文件查看",systemImage: "doc") }
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
            Button("保存副本到文件库",systemImage: "folder.badge.plus") { Task { do { try await model.store?.addFile(name: (document.path as NSString).lastPathComponent,mime: mime,bytes: document.bytes,source: "连接文件夹副本"); error = "已保存原文件副本到文件库" } catch { self.error = error.localizedDescription } } }.padding(.bottom)
        }.navigationTitle((document.path as NSString).lastPathComponent).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { HStack { Button("导出") { exporting = true }; if document.text != nil { Button("保存修改") { Task { do { _ = try await model.connectedFolders?.execute(folderID: folderID,args: ["command": .string("WriteFile"),"filePath": .string(document.path),"content": .string(text),"overwrite": .bool(true),"expectedVersion": .string(document.version)]); dismiss() } catch { self.error = error.localizedDescription } } } } } }
        }.task { text = document.text ?? ""; if mime.hasPrefix("image/") { image = (try? await EmbeddedImages.shared.prepareWallpaper(document.bytes)) ?? "" } }
        }.frame(minWidth: 360,minHeight: 500)
        .fileExporter(isPresented: $exporting,document: BinaryExportDocument(data: document.bytes),contentType: UTType(mimeType: mime) ?? .data,defaultFilename: (document.path as NSString).lastPathComponent) { result in if case .failure(let e) = result, (e as? CocoaError)?.code != .userCancelled { error = e.localizedDescription } }
    }
}
struct ConnectedBackupsView: View {
    let model: ChatViewModel; let folderID: String
    @State private var backups: [FolderItem] = []
    @State private var error: String?
    @State private var restoring: FolderItem?
    var body: some View {
        List { if let error { Text(error).foregroundStyle(.red) }; ForEach(backups) { backup in Button { restoring = backup } label: { VStack(alignment: .leading,spacing: 5) { Text(backup.value["path"].text); Text(backup.value["operation"].text + " · " + Date(timeIntervalSince1970: (backup.value["createdAt"].number ?? 0) / 1000).formatted()).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain) } }.navigationTitle("修改备份").task { await refresh() }
        .confirmationDialog("恢复备份到原位置？当前文件也会先保留一份备份。",isPresented: Binding(get: { restoring != nil },set: { if !$0 { restoring = nil } }),titleVisibility: .visible) { Button("恢复备份") { guard let backup = restoring else { return }; Task { do { let engine = model.connectedFolders; let current = try await engine?.execute(folderID: folderID,args: ["command": .string("FileInfo"),"filePath": backup.value["path"]]); _ = try await engine?.request(.object(["action": .string("restore"),"folderId": .string(folderID),"backupId": .string(backup.id),"expectedVersion": current?["version"] ?? .null])); await refresh() } catch { self.error = error.localizedDescription }; restoring = nil } } }
    }
    func refresh() async { do { backups = try await model.connectedFolders?.request(.object(["action": .string("backups"),"folderId": .string(folderID)])).array.map { FolderItem(value: $0) } ?? [] } catch { self.error = error.localizedDescription } }
}
