import SwiftUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering

struct FileLibraryView: View {
    let model: ChatViewModel
    @Binding var searching: Bool
    @State private var mode = 0
    @State private var files: [LocalFile] = []
    @State private var importing = false
    @State private var removed = false
    @State private var selected: LocalFile?
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice = ""
    init(model: ChatViewModel,searching: Binding<Bool> = .constant(false)) { self.model = model; _searching = searching }
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var visibleFiles: [LocalFile] { files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSegments(titles: ["本机附件","连接文件夹","服务器文件"],selection: $mode,palette: palette).padding(.horizontal,20).padding(.vertical,12)
            if mode == 1 { ConnectedFoldersView(model: model).onDisappear { Task { await refresh() } } }
            else if mode == 2 { ServerFilesView(model: model).onDisappear { Task { await refresh() } } }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 16) {
                        HStack(spacing: 10) {
                            Button("导入文件") { importing = true }.workspaceAction(palette,primary: true).disabled(busy)
                            Button("收集已有聊天附件") { work { let count = try await model.store?.collectAttachmentFiles() ?? 0; await model.refreshAttachmentMetadata(); notice = "已收集 \(count) 个附件，重复内容只保存一份" } }.workspaceAction(palette).disabled(busy || model.synchronizing)
                        }
                        WorkspaceSearch(query: $query,showing: $searching,prompt: "搜索文件名",palette: palette)
                        Toggle("查看已移除文件",isOn: $removed).font(.system(size: 13)).toggleStyle(.switch).foregroundStyle(palette.muted)
                        if let error { Text(error).foregroundStyle(.red) }
                        if !notice.isEmpty { Text(notice).font(.system(size: 13)).foregroundStyle(palette.muted) }
                        ForEach(visibleFiles) { file in
                            Button { selected = file } label: { HStack(spacing: 12) { WorkspaceGlyph(file.mime.hasPrefix("image/") ? "image" : "notes",size: 25).foregroundStyle(palette.accent); VStack(alignment: .leading,spacing: 5) { Text(file.name).font(.system(size: 15,weight: .semibold)).foregroundStyle(palette.ink).lineLimit(2); Text(ByteCountFormatter.string(fromByteCount: Int64(file.size),countStyle: .file) + " · " + file.source).font(.system(size: 12)).foregroundStyle(palette.muted) }; Spacer(); WorkspaceGlyph("chevron",size: 18).foregroundStyle(palette.muted) }.padding(15).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle()) }.workspaceGlass(palette)
                        }
                        if !query.isEmpty && visibleFiles.isEmpty { ContentUnavailableView("没有匹配的文件",systemImage: "magnifyingglass") }
                        else if files.isEmpty { VStack(spacing: 12) { WorkspaceGlyph("folder",size: 36).foregroundStyle(palette.muted); Text(removed ? "没有已移除文件" : "把文件带在身边").font(.system(size: 19,weight: .semibold)); Text("导入文件或收集聊天附件；不会上传到服务器。").font(.system(size: 14)).foregroundStyle(palette.muted).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical,100) }
                    }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                // Each file mode owns its importer; an outer importer masks child presenters.
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { work { let reader = LocalFileImporter(); for url in urls { let (name,mime,data) = try await reader.read(url); try await model.store?.addFile(name: name,mime: mime,bytes: data) }; await model.refreshAttachmentMetadata(); notice = "文件已保存在本机" } }
                }
            }
        }.navigationTitle("文件").buttonStyle(WorkspacePress()).foregroundStyle(palette.ink).background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .task { await refresh() }.onChange(of: removed) { _, _ in Task { await refresh() } }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { LocalFileDetail(model: model, file: $0) }
    }
    func refresh() async { do { files = try await model.store?.localFiles(removed: removed) ?? [] } catch { self.error = error.localizedDescription } }
    func work(_ action: @escaping @MainActor () async throws -> Void) { busy = true; error = nil; Task { defer { busy = false }; do { try await action(); await refresh() } catch { self.error = error.localizedDescription } } }
}
struct LocalFileDetail: View {
    let model: ChatViewModel; let file: LocalFile
    @State private var bytes: Data?
    @State private var preview: FilePreviewContent?
    @State private var exporting = false
    @State private var error: String?
    @State private var attached = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
                if let preview {
                    switch preview {
                    case .image(let data): LocalImagePreview(data: data,title: file.name)
                    case .text(let text): NativeFileText(text: text)
                    case .unsupported: ContentUnavailableView("可导出查看原文件",systemImage: "doc")
                    }
                } else { ContentUnavailableView(bytes == nil ? "正在读取…" : "可导出查看原文件", systemImage: "doc") }
                HStack {
                    Button("导出原文件", systemImage: "square.and.arrow.up") { exporting = true }.disabled(bytes == nil)
                    if file.removedAt == nil {
                        Button(attached ? "已放入当前会话草稿" : "添加到当前会话", systemImage: "paperclip") {
                            Task { do { guard let bytes else { return }; let item = try await AttachmentImporter().prepare(bytes,name: file.name,mime: file.mime); await model.attach([item],to: model.activeTopicID); error = model.room?.error; attached = error == nil } catch { self.error = error.localizedDescription } }
                        }.disabled(bytes == nil || attached)
                    }
                }.padding(.horizontal)
                Button(file.removedAt == nil ? "移到已移除文件" : "恢复文件", systemImage: file.removedAt == nil ? "trash" : "arrow.uturn.backward") { Task { do { try await model.store?.setFileRemoved(file.id,removed: file.removedAt == nil); dismiss() } catch { self.error = error.localizedDescription } } }.padding(.bottom)
            }.navigationTitle(file.name).toolbar { Button("完成") { dismiss() } }
            .task {
                do { let data = try await model.store?.fileBytes(file.id); bytes = data
                    if let data { preview = try await FilePreviewReader().prepare(data,mime: file.mime) }
                } catch { self.error = error.localizedDescription }
            }
        }.frame(minWidth: 360,minHeight: 480)
        .fileExporter(isPresented: $exporting,document: BinaryExportDocument(data: bytes ?? Data()),contentType: UTType(mimeType: file.mime) ?? .data,defaultFilename: file.name) { result in if case .failure(let e) = result, (e as? CocoaError)?.code != .userCancelled { error = e.localizedDescription } }
    }
}
