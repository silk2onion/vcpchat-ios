import SwiftUI
import VChatCore
import VChatRendering
import UniformTypeIdentifiers
struct ServerFilesView: View {
    @Bindable var model: ChatViewModel
    @State private var roots: [String] = []
    @State private var path = ""
    @State private var listing: [RemoteFile] = []
    @State private var truncated = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice = ""
    @State private var importing = false
    @State private var selected: RemoteFile?
    @State private var preview: RemoteFilePreview?
    @State private var destination = ""
    @State private var action = "RenameFile"
    @State private var prompt = false
    @State private var deleting = false
    @State private var connection = false
    @State private var connectionExpanded = true
    func client() -> ServerFileClient { ServerFileClient(configuration: model.configuration,settings: model.services.serverFiles,key: model.apiKey,fileKey: model.serviceSecrets[.fileKey] ?? "") }
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            DisclosureGroup("服务器文件连接",isExpanded: $connectionExpanded) {
                Button("聊天服务器与 API Key") { connection = true }
                TextField("文件工具名称",text: $model.services.serverFiles.toolName)
                TextField("浏览起点（服务器绝对路径）",text: $model.services.serverFiles.root)
                TextField("file/ 分发目录映射",text: $model.services.serverFiles.shareRoot)
                SecureField("File Key（下载原文件）",text: Binding(get: { model.serviceSecrets[.fileKey] ?? "" },set: { model.serviceSecrets[.fileKey] = $0 }))
                Button("保存设置") { work { if !(await model.saveServices()) { throw ClientError.server(model.error ?? "保存失败") }; notice = "设置已保存" } }
                Button("列出允许的目录") { work { roots = try await client().roots() } }
                ForEach(roots,id: \.self) { root in Button(root) { model.services.serverFiles.root = root; work { try await browse(root) } } }
            }
            HStack { TextField("服务器目录",text: $path).onSubmit { work { try await browse(path) } }; Button("打开") { work { try await browse(path.isEmpty ? model.services.serverFiles.root : path) } } }.disabled(busy)
            if !path.isEmpty { Section {
                Button("上一级",systemImage: "arrow.up") { work { var parent = (path as NSString).deletingLastPathComponent; if parent.range(of: "^[A-Za-z]:$",options: .regularExpression) != nil { parent += "/" }; try await browse(try ServerPath.within(model.services.serverFiles.root,parent) ? parent : model.services.serverFiles.root) } }.disabled(path == model.services.serverFiles.root)
                Button("上传文件",systemImage: "square.and.arrow.up") { importing = true }
                Button("新建文件夹",systemImage: "folder.badge.plus") { destination = ""; prompt = true }
            }.disabled(busy) }
            if truncated { Text("服务器返回了部分目录条目").font(.caption).foregroundStyle(.secondary) }
            ForEach(listing) { file in Button { if file.type == "directory" { work { try await browse(file.path) } } else { selected = file; preview = nil } } label: { HStack { Image(systemName: file.type == "directory" ? "folder" : "doc"); VStack(alignment: .leading) { Text(file.name); if let size = file.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size),countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }; Spacer(); Image(systemName: "chevron.right") }.contentShape(Rectangle()) }.buttonStyle(.plain).disabled(busy) }
        }.scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("服务器文件").overlay { if busy { ProgressView().padding(20).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12)) } }
        .task { path = model.services.serverFiles.root }
        .fileImporter(isPresented: $importing,allowedContentTypes: [.data]) { result in if case .success(let url) = result { work { let (name,_,data) = try await LocalFileImporter().read(url); let result = try await client().upload(ServerPath.join(path,name),data: data); notice = result["message"].text.isEmpty ? "服务器已确认上传" : result["message"].text; try await browse(path) } } }
        .sheet(isPresented: $connection) { ConnectionView(model: model) }
        .sheet(item: $selected,onDismiss: { deleting = false }) { file in NavigationStack {
            ScrollView { VStack(alignment: .leading,spacing: 14) {
                Text(file.path).font(.caption).textSelection(.enabled)
                if let error { Text(error).foregroundStyle(.red) }
                if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
                if let preview { if !preview.image.isEmpty { NativeRaster(preview.image,fill: false).frame(height: 260) }; Text(preview.text).textSelection(.enabled) }
                Button("读取提取内容") { work { preview = try await client().read(file.path) } }.disabled(busy)
                Button("下载原文件到本机库") { work { let data = try await client().download(file.path); let type = UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"; try await model.store?.addFile(name: file.name,mime: type,bytes: data,source: "服务器下载"); notice = "原文件已保存到本机文件库" } }.disabled(busy)
                Picker("操作",selection: $action) { Text("改名").tag("RenameFile"); Text("复制").tag("CopyFile"); Text("移动").tag("MoveFile") }
                TextField("目标绝对路径",text: $destination)
                Button("确认执行") { work { try await client().rename(file.path,destination: destination,command: action); selected = nil; notice = "服务器已确认操作完成"; try await browse(path) } }.disabled(destination.isEmpty || busy)
                Button("移入服务器回收站",role: .destructive) { deleting = true }.disabled(busy)
            }.padding(20) }.overlay { if busy { ProgressView().padding(20).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 12)) } }.navigationTitle(file.name).toolbar { Button("完成") { selected = nil } }.onAppear { destination = file.path }
        }.frame(minWidth: 360,minHeight: 520)
            .confirmationDialog("将所选项目移入服务器回收站？",isPresented: $deleting,titleVisibility: .visible) { Button("移入回收站",role: .destructive) { work { try await client().remove(file.path); selected = nil; notice = "服务器已确认移入回收站"; try await browse(path) } } }
        }
        .sheet(isPresented: $prompt) { NavigationStack { Form { TextField("文件夹名称",text: $destination); if let error { Text(error).foregroundStyle(.red) } }.navigationTitle("新建文件夹").toolbar { Button("取消") { prompt = false }; Button("创建") { work { try await client().folder(ServerPath.join(path,destination)); prompt = false; try await browse(path) } }.disabled(destination.isEmpty || busy) } }.frame(minWidth: 340,minHeight: 240) }
    }
    func browse(_ next: String) async throws { let result = try await client().list(next); path = try ServerPath.normalize(next); listing = result.items.sorted { $0.type != $1.type ? $0.type == "directory" : $0.name.localizedStandardCompare($1.name) == .orderedAscending }; truncated = result.truncated }
    func work(_ action: @escaping @MainActor () async throws -> Void) { guard !busy else { return }; busy = true; error = nil; Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } } }
}
