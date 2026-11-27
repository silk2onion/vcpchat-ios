import SwiftUI
import VChatCore
import VChatRendering
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct MessageActions<Content: View>: View {
    let message: MessageViewModel
    let model: ChatViewModel
    @ViewBuilder var content: Content
    @State private var editing = false
    @State private var text = ""
    @State private var copied = false
    @State private var deleting = false
    @Environment(\.openSideQuestion) private var openSideQuestion
    @State private var afterReader: String?
    @State private var selecting = false
    @State private var showingActions = false
    @State private var displayed: String?
    private var idle: Bool { model.rooms[message.topicID]?.busy != true }
    private var canModify: Bool { idle && !model.synchronizing }
    private var last: Bool { model.rooms[message.topicID]?.messages.last?.id == message.id }
    private var streaming: Bool { ["connecting", "streaming"].contains(message.status) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content
                .environment(\.messageLongPressAction, { showingActions = true })
                #if os(iOS)
                .modifier(OriginalUserMenu(enabled: message.role == "user") { menuItems })
                .environment(\.askAboutSelection, message.role == "assistant" ? askAction : nil)
                #else
                .contextMenu { menuItems }
                #endif
                .popover(isPresented: $showingActions) {
                    VStack(alignment: .leading, spacing: 0) {
                        menuItems
                        Divider()
                        Button("取消", role: .cancel) { showingActions = false }
                    }.buttonStyle(MessageMenuButtonStyle()).padding(12).frame(width: 240)
                        .presentationCompactAdaptation(.popover)
                }
            if !streaming { controls.fixedSize(horizontal: message.role == "user", vertical: false) }
        }
        .task(id: DisplayInput(text: streaming ? "" : message.text, rules: model.displayRules(for: message), depth: model.rooms[message.topicID]?.depths[message.id] ?? 0)) {
            guard !streaming else { displayed = nil; return }
            do { let value = try await model.displayedText(message); if !Task.isCancelled { displayed = value } }
            catch { if !Task.isCancelled { model.rooms[message.topicID]?.error = error.localizedDescription } }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                VStack(spacing: 12) { TextEditor(text: $text).scrollContentBackground(.hidden).font(.body); if let error = model.rooms[message.topicID]?.error { Text(error).foregroundStyle(.red).font(.caption) } }.padding(16)
                    .workspacePageSurface().navigationTitle("编辑消息")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { if await model.editMessage(message, text: text) { editing = false } } }.disabled(!canModify) }
                    }
            }.frame(minWidth: 350, minHeight: 400)
        }
        .sheet(isPresented: $selecting, onDismiss: {
            if let afterReader { openSideQuestion?(message, afterReader); self.afterReader = nil }
        }) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading,spacing: 16) {
                        if !message.reasoning.isEmpty {
                            Text("思考过程").font(.headline)
                            MessageProse(AttributedString(message.reasoning), style: .note)
                            Divider()
                        }
                        MessageProse(AttributedString(displayed ?? message.text))
                    }.frame(maxWidth: .infinity,alignment: .leading).padding(20)
                }
                    .environment(\.askAboutSelection, { quote in afterReader = quote; selecting = false })
                    .workspacePageSurface().navigationTitle("选择文字")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selecting = false } } }
            }.frame(minWidth: 350,minHeight: 400)
        }
        .confirmationDialog("从对话中移除？可以在“已删除消息”中恢复。", isPresented: $deleting, titleVisibility: .visible) {
            Button("移除消息", role: .destructive) { Task { await model.trashMessage(message) } }.disabled(!canModify)
            Button("取消", role: .cancel) {}
        }
    }
    private var askAction: @MainActor @Sendable (String) -> Void {
        { quote in openSideQuestion?(message, quote) }
    }
    private var controls: some View {
        HStack(spacing: 18) {
            Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }.accessibilityLabel("复制消息")
            if message.role == "assistant" && last && canModify && ["interrupted", "stopped", "failed"].contains(message.status) { Button { model.regenerate(message, continuing: true) } label: { Label("继续写", systemImage: "arrow.forward.circle") } }
            if message.role == "assistant" { Button { read() } label: { Image(systemName: "speaker.wave.2") }.accessibilityLabel("朗读消息") }
            Spacer(minLength: 4)
            Menu { menuItems } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("消息操作")
        }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    }
    @ViewBuilder private var menuItems: some View {
        Button("复制消息", systemImage: "doc.on.doc") { copy() }
        Button("选择文字", systemImage: "text.cursor") {
            showingActions = false
            Task {
                do { displayed = try await model.displayedText(message); selecting = true }
                catch { model.rooms[message.topicID]?.error = error.localizedDescription }
            }
        }
        ShareLink(item: displayed ?? "") { Label("分享消息", systemImage: "square.and.arrow.up") }.disabled(displayed == nil)
        if message.role == "assistant" { Button("朗读消息", systemImage: "speaker.wave.2") { read() } }
        Divider()
        Button("从这里另开话题", systemImage: "arrow.triangle.branch") {
            showingActions = false
            Task { await model.branch(from: message) }
        }.disabled(model.synchronizing)
        Button("编辑文字", systemImage: "pencil") { showingActions = false; text = message.text; editing = true }.disabled(!canModify)
        if message.role == "assistant" && last {
            Button("继续写", systemImage: "arrow.forward.circle") { showingActions = false; model.regenerate(message, continuing: true) }.disabled(!canModify)
            Button("重新生成", systemImage: "arrow.clockwise") { showingActions = false; model.regenerate(message, continuing: false) }.disabled(!canModify)
        }
        Divider()
        Button("删除消息", systemImage: "trash", role: .destructive) { showingActions = false; deleting = true }.disabled(!canModify)
    }
    private func read() {
        showingActions = false
        Task { do { let text = try await model.displayedText(message); model.speech.read(id: message.id,content: text,settings: model.services.speech,key: model.serviceSecrets[.speechKey] ?? "",agent: model.authorAgent(for: message)) } catch { model.rooms[message.topicID]?.error = error.localizedDescription } }
    }
    private struct DisplayInput: Equatable { var text: String; var rules: [RegexRule]; var depth: Int }
    private func copy() {
        showingActions = false
        Task {
        do { let text = try await model.displayedText(message)
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        } catch { model.rooms[message.topicID]?.error = error.localizedDescription }
        }
    }
}
private struct OriginalUserMenu<Items: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder var items: Items
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.contextMenu { items } } else { content }
    }
}

private struct SideQuestionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (MessageViewModel, String) -> Void)? = nil
}
extension EnvironmentValues {
    var openSideQuestion: (@MainActor @Sendable (MessageViewModel, String) -> Void)? {
        get { self[SideQuestionKey.self] }
        set { self[SideQuestionKey.self] = newValue }
    }
}
struct SideQuestionView: View {
    let model: ChatViewModel
    let source: MessageViewModel
    let quote: String
    @State private var topic: ChatTopic?
    @FocusState private var composing: Bool
    @State private var question = ""
    @State private var preparing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var room: ChatRoom? { topic.flatMap { model.rooms[$0.id] } }
    private var canSend: Bool { !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !preparing && !model.synchronizing }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if room?.messages.isEmpty != false {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("引用原句", systemImage: "quote.opening").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(verbatim: quote).textSelection(.enabled)
                                }.padding(.leading, 12).overlay(alignment: .leading) { Capsule().fill(model.appearance.theme.tint).frame(width: 3) }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(WorkspacePalette(theme: model.appearance.theme).soft, in: RoundedRectangle(cornerRadius: 14))
                            }
                            ForEach(room?.messages ?? []) { message in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.authorName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    RichMessageBody(message.text, options: model.renderOptions, streaming: ["streaming","connecting"].contains(message.status), rules: model.displayRules(for: message), role: message.role, depth: room?.depths[message.id] ?? 0, assistantSegments: message.assistantSegments)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(WorkspacePalette(theme: model.appearance.theme).soft, in: RoundedRectangle(cornerRadius: 14)).id(message.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.onChange(of: room?.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
                }
                if let issue = error ?? room?.error { Text(issue).font(.callout).foregroundStyle(.red).padding(.horizontal) }
                HStack(alignment: .bottom) {
                    TextField("就这句话提问…", text: $question, axis: .vertical).focused($composing).accessibilityIdentifier("side-question-input").lineLimit(1...6).textFieldStyle(.plain).padding(12)
                    if let room, room.busy {
                        Button { Task { await model.stop(in: room.id) } } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.accessibilityLabel("停止生成")
                    } else {
                        Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44,height: 44) }.disabled(!canSend).accessibilityLabel("发送追问")
                    }
                }.padding(.horizontal, 6).workspaceGlass(WorkspacePalette(theme: model.appearance.theme),radius: 20).padding()
            }.workspacePageSurface().navigationTitle("单独追问")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDragIndicator(.visible).onAppear { composing = true }
    }
    private func submit() {
        guard canSend else { return }
        guard !model.apiKey.isEmpty else { error = "请先设置聊天 API Key"; return }
        preparing = true; error = nil
        let input = question
        Task {
            defer { preparing = false }
            do {
                let destination: ChatTopic
                if let topic { destination = topic }
                else { destination = try await model.questionTopic(sourceID: source.topicID, quote: quote); topic = destination }
                guard let room = model.rooms[destination.id] else { return }
                let citation = quote.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                room.draft = room.messages.isEmpty ? citation + "\n\n" + input : input
                model.send(in: destination.id, routingText: input) { if question == input { question = ""; composing = false } }
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MessageMenuButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,10).frame(minHeight: 44)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear,in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
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
            WorkspaceList {
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
    static var readableContentTypes: [UTType] { [.plainText, .json] }
    var text: String
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
