import SwiftUI
import VChatCore
import VChatRendering
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct WorkspaceView: View {
    enum Tab { case chats, contacts, me }
    @Bindable var model: ChatViewModel
    @State private var tab = Tab.chats
    @State private var chatPath: [String] = []
    @State private var editingGroup: VCPGroup?
    @State private var editing: VCPAgent?
    @State private var search = ""
    @State private var settings = false
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $chatPath) {
                List {
                    if let main = model.mainAgent {
                        Section {
                            Button { openAgent(main) } label: {
                                HStack(spacing: 14) {
                                    ContactAvatar(name: main.name, image: main.avatarUrl, size: 50)
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
                                    ContactAvatar(name: agent?.name ?? "会话", image: agent?.avatarUrl ?? "", size: 44)
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
            }.tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.chats)
            NavigationStack {
                List {
                    ForEach(orderedAgents) { agent in
                        HStack(spacing: 12) {
                            Button { openAgent(agent) } label: {
                                HStack(spacing: 12) {
                                    ContactAvatar(name: agent.name, image: agent.avatarUrl, size: 46)
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
                                        ContactAvatar(name: group.name, image: group.avatarUrl, size: 46)
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
            }.tabItem { Label("通讯录", systemImage: "person.2") }.tag(Tab.contacts)
            NavigationStack {
                List {
                    Section {
                        NavigationLink { ProfileEditor(model: model, profile: model.profile) } label: { HStack(spacing: 16) {
                            ContactAvatar(name: model.profile.name.isEmpty ? "我" : model.profile.name, image: model.profile.avatar, size: 64)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.profile.name.isEmpty ? "我" : model.profile.name).font(.title2.bold())
                                Text("你的 VCP 随身工作台").font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 20) }
                    }
                    Section { Button { settings = true } label: { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) } }
                }.scrollContentBackground(.hidden).background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("我")
            }.tabItem { Label("我", systemImage: "person.crop.circle") }.tag(Tab.me)
        }
        .preferredColorScheme(model.appearance.theme == .paper ? .light : .dark)
        .tint(model.appearance.theme.tint)
        .sheet(item: $editing) { agent in AgentEditor(model: model, agent: agent) }
        .sheet(item: $editingGroup) { group in GroupEditor(model: model, group: group) }
        .sheet(isPresented: $settings) { SettingsView(model: model) }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    var orderedAgents: [VCPAgent] {
        model.agents.filter { search.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(search) }.sorted {
            if ($0.id == model.profile.mainAgentID) != ($1.id == model.profile.mainAgentID) { return $0.id == model.profile.mainAgentID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func openAgent(_ agent: VCPAgent) { Task { await model.openAgent(agent); tab = .chats; chatPath = [model.activeTopicID] } }
    func openTopic(_ topic: ChatTopic) { Task { await model.openTopic(topic); chatPath = [topic.id] } }
}
struct ContactAvatar: View {
    let name: String
    var image = ""
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
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.27)).accessibilityLabel(name)
        .task(id: image) { let value = await AvatarImageCache.shared.image(image); if !Task.isCancelled { decodedAvatar = value } }
    }
    var initials: some View { Text(String(name.prefix(1))).font(.system(size: size * 0.4, weight: .semibold)).frame(width: size, height: size).background(.mint.opacity(0.17)).foregroundStyle(.primary) }
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
                    Button { avatar = true } label: { HStack { ContactAvatar(name: agent.name, image: agent.avatarUrl, size: 62); Spacer(); Label("编辑头像", systemImage: "camera") } }.buttonStyle(.plain)
                    TextField("名字", text: $agent.name)
                    TextField("简介", text: $agent.description, axis: .vertical).lineLimit(2...4)
                }
                Section("系统提示词") { TextEditor(text: $agent.systemPrompt).frame(minHeight: 140) }
                Section("模型") {
                    TextField("留空使用全局模型", text: $agent.model)
                    Button("从模型列表选择") { choosingModel = true }
                    Toggle("独立 Temperature", isOn: Binding(get: { agent.temperature != nil }, set: { agent.temperature = $0 ? model.configuration.temperature : nil }))
                    if let temperature = agent.temperature { LabeledContent("Temperature", value: temperature.formatted(.number.precision(.fractionLength(2)))); Slider(value: Binding(get: { agent.temperature ?? 0.8 }, set: { agent.temperature = $0 }), in: 0...2) }
                    Text("只有全局打开“发送 Temperature”时才发送此参数。").font(.caption).foregroundStyle(.secondary)
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
