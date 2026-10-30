import SwiftUI
import VChatCore

struct ChatView: View {
    @Bindable var model: ChatViewModel
    @State private var showTopics = false
    @State private var showAgent = false
    @State private var showGroup = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showLog = false
    @FocusState private var writing: Bool
    var body: some View {
        Group {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(model.busy ? Color.mint : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(model.connection).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.configuration.model.isEmpty ? "未选择模型" : model.configuration.model).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 9)
                if let error = model.error {
                    HStack { Text(error).font(.callout); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(14).background(.red.opacity(0.09)).foregroundStyle(.red)
                }
                ChatTimeline(model: model)
                if model.pendingCount > 0 { Text("\(model.pendingCount) 条本机待确认消息；不会自动重复发送").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("发消息", text: $model.draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).focused($writing).padding(.vertical, 10)
                    if model.busy { Button { Task { await model.stop() } } label: { Image(systemName: "stop.fill").frame(width: 40, height: 40) }.accessibilityLabel("停止生成") }
                    else { Button { model.send(); writing = true } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 40, height: 40).background(.mint, in: Circle()).foregroundStyle(.black) }.disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.loading).accessibilityLabel("发送消息") }
                }.buttonStyle(.plain).padding(.horizontal, 15).padding(.vertical, 5).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 25)).overlay(RoundedRectangle(cornerRadius: 25).stroke(.secondary.opacity(0.15))).padding(.horizontal, 16).padding(.bottom, 12)
            }
            .navigationTitle(model.ownerName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { if model.activeGroup != nil { showGroup = true } else { showAgent = true } } label: {
                        VStack(spacing: 2) { Text(model.ownerName).font(.headline); Text(model.activeTopic?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.buttonStyle(.plain)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showTopics = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("历史话题")
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索本机消息")
                    Button { showLog = true } label: { Image(systemName: "waveform.path") }.accessibilityLabel("VCPLog")
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("连接设置")
                }
            }
            .sheet(isPresented: $showTopics) { TopicsView(model: model) }
            .sheet(isPresented: $showGroup) { if let group = model.activeGroup { GroupEditor(model: model, group: group) } }
            .sheet(isPresented: $showAgent) { if let agent = model.activeAgent { AgentEditor(model: model, agent: agent) } }
            .sheet(isPresented: $showSettings) { ConnectionView(model: model) }
            .sheet(isPresented: $showSearch) {
                NavigationStack { List { TextField("搜索本机消息（至少 3 个字）", text: $model.search).onChange(of: model.search) { _, _ in Task { await model.searchLocal() } }; ForEach(model.results) { Text($0.content).lineLimit(5) } }.navigationTitle("本机搜索").toolbar { Button("完成") { showSearch = false } } }.frame(minWidth: 340, minHeight: 420)
            }
            .sheet(isPresented: $showLog) {
                NavigationStack { List { LabeledContent("WebSocket", value: model.pushStatus); ForEach(Array(model.pushEvents.enumerated()), id: \.offset) { _, item in Text(item).font(.caption.monospaced()).textSelection(.enabled) } }.navigationTitle("VCPLog").toolbar { Button("完成") { showLog = false } } }.frame(minWidth: 340, minHeight: 420)
            }
        }
    }
}

/// The high-frequency scroll trigger is isolated from navigation and the composer.
private struct ChatTimeline: View {
    let model: ChatViewModel
    @State private var followLatest = true
    @State private var openSettings = false
    var body: some View {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            if model.messages.isEmpty && !model.loading {
                                VStack(alignment: .leading, spacing: 12) {
                                    Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(.mint)
                                    Text("有什么想聊的？").font(.title2.bold())
                                    Text("连接你的 VCP，开始一段对话。历史保存在本机。").foregroundStyle(.secondary)
                                    if model.apiKey.isEmpty { Button("连接服务器") { openSettings = true }.buttonStyle(.borderedProminent).tint(.mint) }
                                }.padding(.top, 68).padding(.bottom, 30)
                            }
                            ForEach(model.messages) { message in NativeMessageRow(message: message).id(message.id) }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding(.horizontal, 20).padding(.vertical, 22)
                    }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == "assistant" { Label(message.authorName, systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            if !message.reasoning.isEmpty { DisclosureGroup("思考过程") { Text(message.reasoning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) } }
            Text(message.text.isEmpty && message.status == "connecting" ? "正在连接…" : message.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if ["interrupted", "stopped"].contains(message.status) { Text(message.status == "interrupted" ? "已中断 · 内容已保留" : "已停止").font(.caption).foregroundStyle(.secondary) }
        }.padding(message.role == "user" ? 15 : 0).background(message.role == "user" ? Color.secondary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 18))
    }
}
