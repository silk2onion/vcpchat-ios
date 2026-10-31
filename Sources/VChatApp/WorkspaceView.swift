import SwiftUI
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct WorkspaceView: View {
    enum Tab: CaseIterable {
        case chats,contacts,discover,me
        var title: String { switch self { case .chats: "会话"; case .contacts: "通讯录"; case .discover: "发现"; case .me: "我" } }
        var icon: String { switch self { case .chats: "chat"; case .contacts: "agents"; case .discover: "discover"; case .me: "person" } }
    }
    enum MeScreen: Hashable { case profile,activity,notes,sync,files,settings }
    @Bindable var model: ChatViewModel
    @State private var tab = Tab.chats
    @State private var chatPath: [String] = []
    @State private var contactPath: [String] = []
    @State private var mePath: [MeScreen] = []
    @State private var searching = false
    @State private var chatQuery = ""
    @State private var search = ""
    @State private var editingGroup: VCPGroup?
    @State private var editing: VCPAgent?
    @State private var choosingMain = false
    @State private var newChat = false
    @State private var avatar = false
    @State private var activityOpen = false
    @State private var activitySection = 0
    @State private var activityFilter = ActivityKind.all
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var motion: Bool { model.renderOptions.motion && !reduceMotion }
    var body: some View {
        ZStack {
            activeRoot.id(tab).transition(.opacity.combined(with: .offset(y: 5)))
                .safeAreaInset(edge: .bottom,spacing: 0) { VStack(spacing: 0) { MiniSpeechPlayer(player: model.speech); if showTabBar { bottomTabs } } }
                .background(ThemeWallpaper(model.appearance,animations: motion).ignoresSafeArea())
                .blur(radius: activityOpen ? 8 : 0).allowsHitTesting(!activityOpen).accessibilityHidden(activityOpen)
            if activityOpen {
                Color.black.opacity(0.44).ignoresSafeArea().onTapGesture { closeActivity() }.transition(.opacity)
                ActivityView(model: model,initialSection: activitySection,initialFilter: activityFilter,close: closeActivity)
                    .frame(maxWidth: 480,maxHeight: .infinity).background(palette.solid.ignoresSafeArea()).frame(maxWidth: .infinity,alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity)).zIndex(2)
            }
        }
        .preferredColorScheme(model.appearance.theme == .paper ? .light : .dark)
        .environment(\.workspaceMotion,motion).environment(\.workspaceTheme,model.appearance.theme)
        .tint(palette.accent).foregroundStyle(palette.ink)
        .sheet(item: $editing) { AgentEditor(model: model,agent: $0) }
        .sheet(item: $editingGroup) { GroupEditor(model: model,group: $0) }
        .sheet(isPresented: $choosingMain) { WorkspaceOwnerPicker(model: model,mainOnly: true,selectAgent: { agent in Task { await model.setMainAgent(agent.id) } }) }
        .sheet(isPresented: $newChat) { WorkspaceOwnerPicker(model: model,selectAgent: { createChat($0.id,"agent") },selectGroup: { createChat($0.id,"group") }) }
        .sheet(isPresented: $avatar) { AvatarEditor(image: Binding(get: { model.profile.avatar },set: { value in var profile = model.profile; profile.avatar = value; Task { await model.saveProfile(profile) } }),name: model.profile.name.isEmpty ? "我" : model.profile.name) }
        .alert("操作未完成",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    @ViewBuilder private var activeRoot: some View {
        switch tab {
        case .chats: chats
        case .contacts: contacts
        case .discover: DiscoverView(model: model,activity: openActivity)
        case .me: me
        }
    }
    private var showTabBar: Bool { !searching && (tab != .chats || chatPath.isEmpty) && (tab != .contacts || contactPath.isEmpty) }
    private var bottomTabs: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases,id: \.self) { item in
                Button { searching = false; withAnimation(motion ? .easeInOut(duration: 0.14) : nil) { tab = item } } label: {
                    VStack(spacing: 4) {
                        WorkspaceGlyph(item.icon,size: 22).overlay(alignment: .topTrailing) { if item == .discover,model.activity.unread > 0 { Circle().fill(.red).frame(width: 7,height: 7).offset(x: 5,y: -1) } }
                        Text(item.title).font(.system(size: 11,weight: .semibold))
                    }.foregroundStyle(tab == item ? palette.accent : palette.muted).frame(maxWidth: .infinity).frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(WorkspacePress()).accessibilityLabel(item.title).accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
        }.padding(.horizontal,14).padding(.top,8).padding(.bottom,10).background(palette.glass).background(.ultraThinMaterial).overlay(alignment: .top) { palette.line.frame(height: 0.5) }
    }
    private var chats: some View {
        NavigationStack(path: $chatPath) {
            ConversationsHome(model: model,searching: $searching,query: $chatQuery,openAgent: openAgent,openTopic: openTopic,chooseMain: { choosingMain = true },newConversation: { newChat = true },activity: { openActivity(0,.all) })
                .navigationDestination(for: String.self) { _ in ChatView(model: model).workspaceDetailNavigation() }
        }
    }
    private var contacts: some View {
        NavigationStack(path: $contactPath) {
            ContactsHome(model: model,searching: $searching,query: $search,openAgent: { agent in Task { await model.openAgent(agent); move { searching = false; contactPath = [model.activeTopicID] } } },editAgent: { editing = $0 },openGroup: { group in Task { await model.openGroup(group); move { searching = false; contactPath = [model.activeTopicID] } } },editGroup: { editingGroup = $0 },newAgent: { editing = VCPAgent() },newGroup: { editingGroup = VCPGroup() })
                .navigationDestination(for: String.self) { _ in ChatView(model: model).workspaceDetailNavigation() }
        }
    }
    private var me: some View {
        NavigationStack(path: $mePath) {
            MeHome(model: model,navigate: { screen in move { mePath.append(screen) } },avatar: { avatar = true },activity: { openActivity(0,.all) },settings: { move { mePath.append(.settings) } })
                .navigationDestination(for: MeScreen.self) { screen in meScreen(screen).workspaceDetailNavigation() }
        }
    }
    @ViewBuilder private func meScreen(_ screen: MeScreen) -> some View {
        switch screen {
        case .profile: ProfileEditor(model: model,profile: model.profile)
        case .activity: ActivityView(model: model)
        case .notes: NotesView(model: model)
        case .sync: SyncView(model: model)
        case .files: FileLibraryView(model: model)
        case .settings: SettingsView(model: model,embedded: true)
        }
    }
    private func openActivity(_ section: Int,_ filter: ActivityKind) { activitySection = section; activityFilter = filter; move { activityOpen = true } }
    private func closeActivity() { withAnimation(motion ? .easeIn(duration: 0.18) : nil) { activityOpen = false } }
    private func createChat(_ id: String,_ type: String) { Task { await model.createTopic(ownerID: id,ownerType: type); move { searching = false; tab = .chats; chatPath = [model.activeTopicID] } } }
    func openAgent(_ agent: VCPAgent) { Task { await model.openAgent(agent); move { searching = false; tab = .chats; chatPath = [model.activeTopicID] } } }
    func openTopic(_ topic: ChatTopic) { Task { await model.openTopic(topic); move { searching = false; chatPath = [topic.id] } } }
    private func move(_ action: () -> Void) { withAnimation(motion ? .timingCurve(0.2,0.7,0.2,1,duration: 0.22) : nil,action) }
}
struct ContactAvatar: View {
    enum Kind { case agent,group,personal }
    let name: String
    var image = ""
    var symbol = ""
    var kind = Kind.agent
    var size: CGFloat = 44
    @Environment(\.workspaceTheme) private var theme
    @State private var decodedAvatar: CGImage?
    var body: some View {
        Group {
            if image.hasPrefix("data:image/gif;") {
                NativeRaster(image)
            } else if image.hasPrefix("data:image") {
                if let decodedAvatar { Image(decorative: decodedAvatar, scale: 1).resizable().scaledToFill() }
                else { initials }
            } else if let url = URL(string: image), ["http", "https"].contains(url.scheme) {
                AsyncImage(url: url) { phase in if let image = phase.image { image.resizable().scaledToFill() } else { initials } }
            } else { initials }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.30)).accessibilityHidden(true)
        .task(id: image) { let value = await AvatarImageCache.shared.image(image); if !Task.isCancelled { decodedAvatar = value } }
    }
    var initials: some View {
        let tones: [(UInt32,UInt32)] = theme == .paper ? [(0x2f7a4e,0xdceee1),(0x7b5d9c,0xede4f6),(0x507daa,0xe2edf9),(0xa07642,0xf8ead4),(0xaa5f75,0xf6e4eb),(0x498b8a,0xdef0ef)] : [(0x96d8b0,0x234936),(0xc6b1ef,0x3d3154),(0x97c3ef,0x263f57),(0xf0c08c,0x513e2d),(0xf0a7bc,0x503341),(0x99d5d5,0x284749)]
        let tone = tones[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % tones.count]
        return Group {
            if kind == .personal { WorkspaceGlyph("person",size: size * 0.52) }
            else if kind == .group { WorkspaceGlyph("agents",size: size * 0.52) }
            else { Text(symbol.isEmpty ? (name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "A") : symbol).lineLimit(1).minimumScaleFactor(0.4) }
        }.font(.system(size: size * 0.42,weight: .semibold)).frame(width: size,height: size).background(Color(rgb: tone.1)).foregroundStyle(Color(rgb: tone.0))
    }
}
struct AgentEditor: View {
    @Bindable var model: ChatViewModel
    @State var agent: VCPAgent
    @State private var choosingModel = false
    @State private var regex = false
    @State private var avatar = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var existing: Bool { model.agents.contains { $0.id == agent.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section("Agent 资料") {
                    Button { avatar = true } label: { HStack { ContactAvatar(name: agent.name, image: agent.avatarUrl, symbol: agent.avatar, size: 62); Spacer(); Label("编辑头像", systemImage: "camera") } }.buttonStyle(.plain)
                    TextField("名字", text: $agent.name)
                    TextField("简介", text: $agent.description, axis: .vertical).lineLimit(2...4)
                    TextField("头像符号（无图片时显示）",text: $agent.avatar)
                }
                Section("系统提示词") { TextEditor(text: $agent.systemPrompt).frame(minHeight: 140) }
                Section("模型") {
                    TextField("留空使用全局模型", text: $agent.model)
                    Button("从模型列表选择") { choosingModel = true }
                    Toggle("独立 Temperature", isOn: Binding(get: { agent.temperature != nil }, set: { agent.temperature = $0 ? model.configuration.temperature : nil }))
                    if let temperature = agent.temperature { LabeledContent("Temperature", value: temperature.formatted(.number.precision(.fractionLength(2)))); Slider(value: Binding(get: { agent.temperature ?? 0.8 }, set: { agent.temperature = $0 }), in: 0...2) }
                    Text("只有全局打开“发送 Temperature”时才发送此参数。").font(.caption).foregroundStyle(.secondary)
                }
                Section("专属语音") {
                    TextField("音色 ID（留空继承全局）", text: $agent.voice)
                    Toggle("继承全局语速",isOn: $agent.speechSpeedInherited)
                    if !agent.speechSpeedInherited { LabeledContent("语速",value: agent.speechSpeed.formatted(.number.precision(.fractionLength(2)))); Slider(value: $agent.speechSpeed,in: 0.5...2,step: 0.05) }
                    TextField("导演提示词（留空继承全局）",text: $agent.speechDirector,axis: .vertical).lineLimit(2...4)
                }
                Section { Button("专属正则 · \(agent.regexRules.count) 条", systemImage: "text.magnifyingglass") { regex = true } }
                if existing {
                    Section {
                        Button(agent.id == model.profile.mainAgentID ? "当前主 Agent" : "设为主 Agent", systemImage: "star") { Task { await model.setMainAgent(agent.id) } }.disabled(agent.id == model.profile.mainAgentID)
                        Button("删除 Agent", role: .destructive) { deleting = true }
                    }
                }
            }.formStyle(.grouped).navigationTitle(existing ? "编辑 Agent" : "添加 Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { if await model.saveAgent(agent) { dismiss() } } }.disabled(agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .sheet(isPresented: $choosingModel) { ModelPicker(model: model, selection: $agent.model) }
            .sheet(isPresented: $regex) { RegexRulesView(title: "Agent 正则", rules: $agent.regexRules) {} }
            .sheet(isPresented: $avatar) { AvatarEditor(image: $agent.avatarUrl, name: agent.name) }
            .confirmationDialog("删除这个 Agent？聊天记录将保留。", isPresented: $deleting, titleVisibility: .visible) { Button("删除 Agent", role: .destructive) { Task { await model.removeAgent(agent.id); if model.error == nil { dismiss() } } } }
        }.frame(minWidth: 340, minHeight: 530)
    }
}
