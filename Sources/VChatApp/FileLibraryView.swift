import SwiftUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering

struct FileLibraryView: View {
    let model: ChatViewModel
    @State private var files: [LocalFile] = []
    @State private var importing = false
    @State private var removed = false
    @State private var selected: LocalFile?
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var notice = ""
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            Section { NavigationLink { ServerFilesView(model: model) } label: { Label("服务器文件",systemImage: "externaldrive.connected.to.line.below") } }
            Section { NavigationLink { ConnectedFoldersView(model: model) } label: { Label("连接文件夹",systemImage: "folder.badge.plus") } }
            Section {
                Button("导入文件", systemImage: "square.and.arrow.down") { importing = true }.disabled(busy)
                Button("收集聊天附件副本", systemImage: "bubble.left.and.text.bubble.right") { work { let count = try await model.store?.collectAttachmentFiles() ?? 0; await model.refreshAttachmentMetadata(); notice = "已收集 \(count) 个附件，重复内容只保存一份" } }.disabled(busy || model.synchronizing)
                Toggle("查看已移除文件", isOn: $removed)
            }
            ForEach(files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { file in
                Button { selected = file } label: {
                    HStack(spacing: 12) { Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc").font(.title3); VStack(alignment: .leading, spacing: 5) { Text(file.name).foregroundStyle(.primary); Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) + " · " + file.source).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if files.isEmpty { ContentUnavailableView(removed ? "没有已移除文件" : "文件库为空", systemImage: "folder") }
        }.navigationTitle("文件").searchable(text: $query, prompt: "搜索文件名")
        .task { await refresh() }.onChange(of: removed) { _, _ in Task { await refresh() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { work { let reader = LocalFileImporter(); for url in urls { let (name,mime,data) = try await reader.read(url); try await model.store?.addFile(name: name,mime: mime,bytes: data) }; await model.refreshAttachmentMetadata(); notice = "文件已保存在本机" } }
        }
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
