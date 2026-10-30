import SwiftUI
import VChatCore
import VChatRendering
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var model: ChatViewModel
    @State private var showTopics = false
    @State private var showAgent = false
    @State private var showGroup = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showLog = false
    @State private var showDeleted = false
    @State private var exporting = false
    @State private var exportDocument = TextExportDocument()
    @State private var newlineRequest = 0
    var body: some View {
        Group {
            VStack(spacing: 0) {
                #if os(macOS)
                HStack(spacing: 4) { titleButton; Spacer(minLength: 0); headerActions }.buttonStyle(.plain).padding(.horizontal,12).padding(.vertical,5).background(.regularMaterial)
                #endif
                HStack(spacing: 7) {
                    Circle().fill(model.busy ? Color.mint : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(model.connection).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.modelTitle).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 9)
                if let error = model.room?.error ?? model.error {
                    HStack { Text(error).font(.callout); Spacer(); Button { model.room?.error = nil; model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(14).background(.red.opacity(0.09)).foregroundStyle(.red)
                }
                ChatTimeline(model: model)
                if model.pendingCount > 0 { Text("\(model.pendingCount) 条本机待确认消息；不会自动重复发送").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if let room = model.room, !room.attachments.isEmpty { AttachmentStrip(attachments: room.attachments) { id in Task { await model.detach(id) } }.padding(.horizontal, 16).padding(.bottom, 6) }
                HStack(alignment: .bottom, spacing: 8) {
                    AttachmentComposer(model: model)
                    NativeComposer(text: $model.draft, enterSends: model.inputPreferences.enterSends, insertNewline: newlineRequest) { if !model.busy { model.send() } }
                    if model.inputPreferences.enterSends { Button { newlineRequest += 1 } label: { Image(systemName: "return").frame(width: 32, height: 40) }.accessibilityLabel("换行") }
                    if model.busy { Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 40, height: 40) }.accessibilityLabel("停止生成") }
                    else { Button { model.send() } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 40, height: 40).background(model.appearance.theme.tint, in: Circle()).foregroundStyle(model.appearance.theme == .paper ? .white : .black) }.disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.room?.attachments.isEmpty ?? true) || model.loading).accessibilityLabel("发送消息") }
                }.buttonStyle(.plain).padding(.horizontal, 15).padding(.vertical, 5).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 25)).overlay(RoundedRectangle(cornerRadius: 25).stroke(.secondary.opacity(0.15))).padding(.horizontal, 16).padding(.bottom, 12)
            }
            .background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea())
            .navigationTitle(model.ownerName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .principal) { titleButton }
                ToolbarItemGroup(placement: .primaryAction) { headerActions }
                #endif
            }
            .sheet(isPresented: $showDeleted) { DeletedMessagesView(model: model, topicID: model.activeTopicID) }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .plainText, defaultFilename: (model.activeTopic?.title ?? "对话") + ".md") { result in if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { model.error = error.localizedDescription } }
            .sheet(isPresented: $showTopics) { TopicsView(model: model) }
            .sheet(isPresented: $showGroup) { if let group = model.activeGroup { GroupEditor(model: model, group: group) } }
            .sheet(isPresented: $showAgent) { if let agent = model.activeAgent { AgentEditor(model: model, agent: agent) } }
            .sheet(isPresented: $showSettings) { ConnectionView(model: model) }
            .sheet(isPresented: $showSearch) {
                NavigationStack { List { TextField("搜索本机消息（至少 3 个字）", text: $model.search).onChange(of: model.search) { _, _ in Task { await model.searchLocal() } }; ForEach(model.results) { Text($0.content).lineLimit(5) } }.navigationTitle("本机搜索").toolbar { Button("完成") { showSearch = false } } }.frame(minWidth: 340, minHeight: 420)
            }
            .sheet(isPresented: $showLog) { NavigationStack { ActivityView(model: model).toolbar { Button("完成") { showLog = false } } }.frame(minWidth: 360,minHeight: 530) }
        }
    }
    private var titleButton: some View {
        Button { if model.activeGroup != nil { showGroup = true } else { showAgent = true } } label: {
            HStack(spacing: 8) {
                ContactAvatar(name: model.ownerName,image: model.activeGroup?.avatarUrl ?? model.activeAgent?.avatarUrl ?? "",symbol: model.activeAgent?.avatar ?? "",kind: model.activeGroup == nil ? .agent : .group,size: 28)
                VStack(alignment: .leading,spacing: 2) { Text(model.ownerName).font(.headline).lineLimit(1); Text(model.activeTopic?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }.frame(maxWidth: 150,alignment: .leading)
            }
        }.buttonStyle(.plain).accessibilityLabel("编辑 " + model.ownerName)
    }
    private var headerActions: some View {
        Group {
            Button { showTopics = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 36,height: 44) }.accessibilityLabel("历史话题")
            Button { showLog = true } label: { Image(systemName: model.activity.unread > 0 ? "bell.badge" : "bell").frame(width: 36,height: 44) }.accessibilityLabel("通知与监视")
            Menu {
                Button("搜索本机消息",systemImage: "magnifyingglass") { showSearch = true }
                Button("连接设置",systemImage: "slider.horizontal.3") { showSettings = true }
                Button("导出这段对话",systemImage: "square.and.arrow.up") { exportDocument = TextExportDocument(text: TranscriptExport.markdown(title: model.activeTopic?.title ?? "对话",messages: model.messages.map(\.record))); exporting = true }
                Button("已删除消息",systemImage: "trash") { showDeleted = true }
            } label: { Image(systemName: "ellipsis").frame(width: 36,height: 44) }.accessibilityLabel("对话菜单")
        }
    }

}

/// The high-frequency scroll trigger is isolated from navigation and the composer.
private struct ChatTimeline: View {
    let model: ChatViewModel
    @State private var followLatest = true
    @State private var openSettings = false
    @State private var viewport = CGRect.zero
    var body: some View {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if model.messages.isEmpty && !model.loading {
                                VStack(alignment: .leading, spacing: 12) {
                                    Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(.mint)
                                    Text("有什么想聊的？").font(.title2.bold())
                                    Text("连接你的 VCP，开始一段对话。历史保存在本机。").foregroundStyle(.secondary)
                                    if model.apiKey.isEmpty { Button(model.credentialsLocked ? "解锁已有连接" : "连接服务器") { openSettings = true }.buttonStyle(.borderedProminent).tint(.mint) }
                                }.padding(.top, 68).padding(.bottom, 30)
                            }
                            ForEach(model.messages) { message in NativeMessageRow(message: message, model: model).id(message.id) }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(.horizontal, 20).padding(.vertical, 22)
                    }
                    .environment(\.messageViewport, viewport)
                    .background(GeometryReader { geometry in Color.clear.preference(key: ChatViewport.self, value: geometry.frame(in: .global)) })
                    .onPreferenceChange(ChatViewport.self) { value in Task { @MainActor in viewport = value } }
                    .defaultScrollAnchor(model.messages.isEmpty ? .top : .bottom)
                    .onChange(of: model.frames) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                    .onChange(of: model.messages.count) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
                    .overlay(alignment: .bottomTrailing) {
                        Button { followLatest.toggle(); if followLatest { proxy.scrollTo("latest", anchor: .bottom) } } label: { Image(systemName: followLatest ? "pause.circle" : "arrow.down.circle.fill").font(.title2) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(16).accessibilityLabel(followLatest ? "暂停跟随回复" : "跟随最新回复")
                    }
                }
            .sheet(isPresented: $openSettings) { ConnectionView(model: model) }
    }
}

private struct NativeMessageRow: View {
    let message: MessageViewModel
    let model: ChatViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == "assistant" {
                let author = model.authorAgent(for: message),name = message.authorName.isEmpty ? author?.name ?? "助手" : message.authorName
                HStack(spacing: 8) { ContactAvatar(name: name, image: author?.avatarUrl ?? "", symbol: author?.avatar ?? "", size: 25); Text(name) }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !message.attachments.isEmpty { AttachmentStrip(attachments: message.attachments) }
            if let notice = message.syncNotice { Label(notice, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
            if !message.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } }
            RichMessageBody(message.text.isEmpty && message.status == "connecting" ? "正在连接…" : message.text, options: model.renderOptions, streaming: ["connecting", "streaming"].contains(message.status), rules: model.displayRules(for: message), role: message.role, depth: model.rooms[message.topicID]?.depths[message.id] ?? 0).font(.body)
            if !["streaming", "connecting"].contains(message.status) { MessageActions(message: message, model: model) }
            if ["interrupted", "stopped"].contains(message.status) { Text(message.status == "interrupted" ? "已中断 · 内容已保留" : "已停止").font(.caption).foregroundStyle(.secondary) }
        }.padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ChatViewport: PreferenceKey { static let defaultValue = CGRect.zero; static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() } }
