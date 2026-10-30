import SwiftUI
import VChatCore
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct MessageActions: View {
    let message: MessageViewModel
    let model: ChatViewModel
    @State private var editing = false
    @State private var text = ""
    @State private var copied = false
    @State private var deleting = false
    private var idle: Bool { model.rooms[message.topicID]?.busy != true }
    private var last: Bool { model.rooms[message.topicID]?.messages.last?.id == message.id }
    var body: some View {
        HStack(spacing: 18) {
            Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.accessibilityLabel("复制消息")
            if message.role == "assistant" && last && idle && ["interrupted", "stopped", "failed"].contains(message.status) { Button { model.regenerate(message, continuing: true) } label: { Label("继续写", systemImage: "arrow.forward.circle") } }
            Spacer(minLength: 4)
            Menu {
                ShareLink(item: message.text) { Label("分享消息", systemImage: "square.and.arrow.up") }
                Button("编辑文字", systemImage: "pencil") { text = message.text; editing = true }.disabled(!idle)
                if message.role == "assistant" && last {
                    Button("继续写", systemImage: "arrow.forward.circle") { model.regenerate(message, continuing: true) }.disabled(!idle)
                    Button("重新生成", systemImage: "arrow.clockwise") { model.regenerate(message, continuing: false) }.disabled(!idle)
                }
                Button("移到已删除消息", systemImage: "trash", role: .destructive) { deleting = true }.disabled(!idle)
            } label: { Image(systemName: "ellipsis").frame(minWidth: 32, minHeight: 30) }.menuStyle(.borderlessButton).fixedSize()
        }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        .sheet(isPresented: $editing) {
            NavigationStack {
                VStack(spacing: 12) { TextEditor(text: $text).font(.body); if let error = model.rooms[message.topicID]?.error { Text(error).foregroundStyle(.red).font(.caption) } }.padding(16)
                    .navigationTitle("编辑消息")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { if await model.editMessage(message, text: text) { editing = false } } }.disabled(!idle) }
                    }
            }.frame(minWidth: 350, minHeight: 400)
        }
        .confirmationDialog("从对话中移除？可以在“已删除消息”中恢复。", isPresented: $deleting, titleVisibility: .visible) { Button("移除消息", role: .destructive) { Task { await model.trashMessage(message) } } }
    }
    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = message.text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string)
        #endif
        copied = true
    }
}
struct DeletedMessagesView: View {
    let model: ChatViewModel
    let topicID: String
    @State private var deleted: [MessageBackup] = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if deleted.isEmpty { ContentUnavailableView("没有已删除消息", systemImage: "trash") }
                ForEach(deleted) { backup in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(backup.message.authorName).font(.caption).foregroundStyle(.secondary)
                        Text(backup.message.content).lineLimit(5)
                        Button("恢复到对话", systemImage: "arrow.uturn.backward") { Task { if await model.restoreMessage(backup) { deleted.removeAll { $0.id == backup.id } } else { error = model.error } } }.disabled(model.rooms[topicID]?.busy == true)
                    }.padding(.vertical, 6)
                }
            }.navigationTitle("已删除消息").toolbar { Button("完成") { dismiss() } }
                .task { do { deleted = try await model.store?.records(MessageBackup.self, kind: "message-trash").filter { $0.message.topicID == topicID } ?? [] } catch { self.error = error.localizedDescription } }
        }.frame(minWidth: 350, minHeight: 450)
    }
}
struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
