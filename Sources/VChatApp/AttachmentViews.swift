import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering

struct AttachmentComposer: View {
    let model: ChatViewModel
    @State private var importing = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importTopic = ""
    @State private var loading = false
    var body: some View {
        Menu {
            Button("图片或文本文件", systemImage: "folder") { importTopic = model.activeTopicID; importing = true }
            PhotosPicker(selection: $photos, maxSelectionCount: max(1, 4 - (model.room?.attachments.count ?? 0)), matching: .images) { Label("照片图库", systemImage: "photo") }
        } label: { Image(systemName: loading ? "hourglass" : "plus").frame(width: 32, height: 40) }.disabled(loading || model.busy).accessibilityLabel("添加附件")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .text, .json, .xml, .data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let topic = importTopic; loading = true
                Task { defer { loading = false }; do { try AttachmentImporter.assertCount(model.rooms[topic]?.attachments.count ?? 0, adding: urls.count); var items: [ChatAttachment] = []; let reader = AttachmentImporter(); for url in urls { items.append(try await reader.read(url)) }; await model.attach(items, to: topic) } catch { model.rooms[topic]?.error = error.localizedDescription } }
            }
        }
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            let topic = model.activeTopicID; loading = true
            Task {
                defer { loading = false; photos = [] }
                do {
                    try AttachmentImporter.assertCount(model.rooms[topic]?.attachments.count ?? 0, adding: selection.count)
                    var items: [ChatAttachment] = []; let reader = AttachmentImporter()
                    for (index, item) in selection.enumerated() {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ClientError.server("无法读取照片") }
                        let type = item.supportedContentTypes.first ?? .image
                        items.append(try await reader.prepare(data, name: "照片\(index + 1).\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg"))
                    }
                    await model.attach(items, to: topic)
                } catch { model.rooms[topic]?.error = error.localizedDescription }
            }
        }
    }
}
struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    var remove: ((String) -> Void)?
    @State private var preview: ChatAttachment?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { item in
                    HStack(spacing: 8) {
                        Button { preview = item } label: {
                            HStack(spacing: 8) {
                                if let source = item.dataUrl { NativeRaster(source).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                else { Image(systemName: item.desktopOnly == true ? "icloud.and.arrow.down" : "doc.text").font(.title3) }
                                VStack(alignment: .leading) { Text(item.name).lineLimit(1); if item.desktopOnly == true { Text("原文件待下载").font(.caption2).foregroundStyle(.secondary) } }
                            }
                        }.buttonStyle(.plain)
                        if let remove { Button { remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("移除附件 \(item.name)") }
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }.sheet(item: $preview) { AttachmentPreview(item: $0) }
    }
}
struct AttachmentPreview: View {
    let item: ChatAttachment
    @State private var exporting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let source = item.dataUrl { NativeRaster(source, fill: false) }
                else if let text = item.text { ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) } }
                else { ContentUnavailableView("原文件尚未下载", systemImage: "icloud.and.arrow.down", description: Text("在文件库导入对应原文件后可重新关联。")) }
            }.safeAreaInset(edge: .bottom) { if let error { Text(error).foregroundStyle(.red).padding() } }.navigationTitle(item.name).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("导出原文件", systemImage: "square.and.arrow.up") { exporting = true }.disabled(item.bytes == nil) }
            }
        }.frame(minWidth: 360, minHeight: 450)
        .fileExporter(isPresented: $exporting, document: BinaryExportDocument(data: item.bytes ?? Data()), contentType: UTType(mimeType: item.mime) ?? .data, defaultFilename: item.name) { result in if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription } }
    }
}
struct BinaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
