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
        case chats, contacts, discover, me
        var title: String { switch self { case .chats: "会话"; case .contacts: "通讯录"; case .discover: "发现"; case .me: "我" } }
        var icon: String { switch self { case .chats: "bubble.left.and.bubble.right"; case .contacts: "person.2"; case .discover: "safari"; case .me: "person.crop.circle" } }
    }
    enum MeScreen: Hashable { case profile,activity,notes,sync,files }
    @Bindable var model: ChatViewModel
    @State private var tab = Tab.chats
    @State private var chatPath: [String] = []
    @State private var mePath: [MeScreen] = []
    @State private var editingGroup: VCPGroup?
    @State private var editing: VCPAgent?
    @State private var search = ""
    @State private var settings = false
    @State private var discoverAtRoot = true
    var body: some View {
        ZStack {
            switch tab {
            case .chats: chats
            case .contacts: contacts
            case .discover: DiscoverView(model: model,atRoot: $discoverAtRoot)
            case .me: me
            }
        }
        .safeAreaInset(edge: .bottom,spacing: 0) {
            VStack(spacing: 0) {
                MiniSpeechPlayer(player: model.speech)
                if showTabBar { bottomTabs }
            }
        }
        .preferredColorScheme(model.appearance.theme == .paper ? .light : .dark)
        .tint(model.appearance.theme.tint)
        .sheet(item: $editing) { agent in AgentEditor(model: model, agent: agent) }
        .sheet(item: $editingGroup) { group in GroupEditor(model: model, group: group) }
        .sheet(isPresented: $settings) { SettingsView(model: model) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var showTabBar: Bool {
        switch tab { case .chats: chatPath.isEmpty; case .contacts: true; case .discover: discoverAtRoot; case .me: mePath.isEmpty }
    }
    private var bottomTabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases,id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon + (tab == item ? ".fill" : ""))
                            .font(.system(size: 23,weight: .regular)).frame(height: 27)
                            .overlay(alignment: .topTrailing) {
                                if item == .discover,model.activity.unread > 0 { Circle().fill(.red).frame(width: 7,height: 7).offset(x: 5,y: -1) }
                            }
                        Text(item.title).font(.system(size: 11,weight: tab == item ? .medium : .regular))
                    }.foregroundStyle(tab == item ? model.appearance.theme.tint : .secondary)
                        .frame(maxWidth: .infinity).frame(minHeight: 55).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(item.title)
                    .accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
        }.padding(.horizontal,10).background(.regularMaterial).overlay(alignment: .top) { Divider() }
    }
    private var chats: some View {
            NavigationStack(path: $chatPath) {
                List {
                    if let main = model.mainAgent {
                        Section {
                            Button { openAgent(main) } label: {
                                HStack(spacing: 14) {
                                    ContactAvatar(name: main.name, image: main.avatarUrl, symbol: main.avatar, size: 50)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(main.name).font(.headline)
                                        Label("主 Agent", systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    Section("最近会话") {
                        ForEach(model.topics.sorted { $0.updatedAt > $1.updatedAt }) { topic in
                            Button { openTopic(topic) } label: {
                                HStack(spacing: 12) {
                                    let agent = model.agents.first { $0.id == topic.ownerId }
                                    let group = model.groups.first { $0.id == topic.ownerId }
                                    ContactAvatar(name: agent?.name ?? group?.name ?? "会话", image: agent?.avatarUrl ?? group?.avatarUrl ?? "", symbol: agent?.avatar ?? "", kind: topic.ownerType == "group" ? .group : .agent, size: 44)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(topic.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(agent?.name ?? model.groups.first(where: { $0.id == topic.ownerId })?.name ?? "已删除的联系人").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.rooms[topic.id]?.busy == true { ProgressView().controlSize(.small) }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea())
                .navigationTitle("会话")
                .navigationDestination(for: String.self) { _ in ChatView(model: model) }
            }
    }
    private var contacts: some View {
            NavigationStack {
                List {
                    ForEach(orderedAgents) { agent in
                        HStack(spacing: 12) {
                            Button { openAgent(agent) } label: {
                                HStack(spacing: 12) {
                                    ContactAvatar(name: agent.name, image: agent.avatarUrl, symbol: agent.avatar, size: 46)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(agent.name).font(.headline); if agent.id == model.profile.mainAgentID { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) } }
                                        Text(agent.description.isEmpty ? (agent.model.isEmpty ? "使用默认模型" : agent.model) : agent.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { editing = agent } label: { Image(systemName: "ellipsis").frame(width: 38, height: 44) }.buttonStyle(.plain).accessibilityLabel("编辑 \(agent.name)")
                        }.padding(.vertical, 4)
                    }
                    Section {
                        ForEach(model.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { group in
                            HStack(spacing: 12) {
                                Button { Task { await model.openGroup(group); tab = .chats; chatPath = [model.activeTopicID] } } label: {
                                    HStack(spacing: 12) {
                                        ContactAvatar(name: group.name, image: group.avatarUrl, kind: .group, size: 46)
                                        VStack(alignment: .leading, spacing: 4) { Text(group.name).font(.headline); Text("\(group.memberIds.count) 位 Agent · \(group.mode.title)").font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { editingGroup = group } label: { Image(systemName: "ellipsis").frame(width: 38, height: 44) }.buttonStyle(.plain).accessibilityLabel("编辑群聊 \(group.name)")
                            }.padding(.vertical, 4)
                        }
                        Button("创建群聊", systemImage: "person.2.badge.plus") { editingGroup = VCPGroup() }
                    } header: { Text("群聊") }
                }
                .scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea())
                .searchable(text: $search, prompt: "搜索 Agent")
                .navigationTitle("通讯录")
                .toolbar { Button { editing = VCPAgent() } label: { Image(systemName: "plus") }.accessibilityLabel("添加 Agent") }
            }
    }
    private var me: some View {
            NavigationStack(path: $mePath) {
                List {
                    Section {
                        NavigationLink(value: MeScreen.profile) { HStack(spacing: 16) {
                            ContactAvatar(name: model.profile.name.isEmpty ? "我" : model.profile.name, image: model.profile.avatar, kind: .personal, size: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.profile.name.isEmpty ? "我" : model.profile.name).font(.title2.bold())
                                Text("你的 VCP 随身工作台").font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 20) }
                    }
                    Section { NavigationLink(value: MeScreen.activity) { HStack { Label("通知与监视", systemImage: model.activity.unread > 0 ? "bell.badge" : "bell"); Spacer(); if model.activity.unread > 0 { Text("\(model.activity.unread)").foregroundStyle(.secondary) } } } }
                    Section { NavigationLink(value: MeScreen.notes) { Label("笔记", systemImage: "note.text") } }
                    Section { NavigationLink(value: MeScreen.sync) { Label("会话同步", systemImage: "arrow.triangle.2.circlepath") } }
                    Section { NavigationLink(value: MeScreen.files) { Label("文件", systemImage: "folder") } }
                    Section { Button { settings = true } label: { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) } }
                }.scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("我")
                .navigationDestination(for: MeScreen.self) { screen in
                    meScreen(screen)
                }
            }
    }
    var orderedAgents: [VCPAgent] {
        model.agents.filter { search.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(search) }.sorted {
            if ($0.id == model.profile.mainAgentID) != ($1.id == model.profile.mainAgentID) { return $0.id == model.profile.mainAgentID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    @ViewBuilder private func meScreen(_ screen: MeScreen) -> some View {
        switch screen {
        case .profile: ProfileEditor(model: model,profile: model.profile)
        case .activity: ActivityView(model: model)
        case .notes: NotesView(model: model)
        case .sync: SyncView(model: model)
        case .files: FileLibraryView(model: model)
        }
    }
    func openAgent(_ agent: VCPAgent) { Task { await model.openAgent(agent); tab = .chats; chatPath = [model.activeTopicID] } }
    func openTopic(_ topic: ChatTopic) { Task { await model.openTopic(topic); chatPath = [topic.id] } }
}
struct ContactAvatar: View {
    enum Kind { case agent,group,personal }
    let name: String
    var image = ""
    var symbol = ""
    var kind = Kind.agent
    var size: CGFloat = 44
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
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.27)).accessibilityHidden(true)
        .task(id: image) { let value = await AvatarImageCache.shared.image(image); if !Task.isCancelled { decodedAvatar = value } }
    }
    var initials: some View {
        let colors: [Color] = [.mint,.blue,.purple,.orange,.pink,.teal]
        let color = colors[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % colors.count]
        return Group {
            if kind == .personal { Image(systemName: "person.fill") }
            else if kind == .group { Image(systemName: "person.2.fill") }
            else { Text(symbol.isEmpty ? String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)) : symbol).lineLimit(1).minimumScaleFactor(0.4) }
        }.font(.system(size: size * 0.4,weight: .semibold)).frame(width: size,height: size).background(color.opacity(0.17)).foregroundStyle(color)
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
