import SwiftUI
import VChatRendering
import VChatCore

struct ConversationsHome: View {
    let model: ChatViewModel
    @Binding var searching: Bool
    @Binding var query: String
    var openAgent: (VCPAgent) -> Void
    var openTopic: (ChatTopic) -> Void
    var chooseMain: () -> Void
    var newConversation: () -> Void
    var activity: () -> Void
    @State private var summaries: [String:ConversationSummary] = [:]
    @State private var error: String?
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var topics: [ChatTopic] { model.topics.sorted { $0.updatedAt > $1.updatedAt }.filter { query.isEmpty || (name($0) + " " + $0.title + " " + (summaries[$0.id]?.display ?? "")).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "会话",subtitle: "VCPCHAT",palette: palette) {
                WorkspaceActivityButton(model: model,action: activity)
                WorkspaceIconButton(icon: "plus",label: "新建会话",accent: true,action: newConversation)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let main = model.mainAgent {
                        HStack(spacing: 4) {
                            Button { openAgent(main) } label: {
                                HStack(spacing: 13) {
                                    ContactAvatar(name: main.name,image: main.avatarUrl,size: 50)
                                    VStack(alignment: .leading,spacing: 3) {
                                        HStack(spacing: 4) { WorkspaceGlyph("star",size: 12); Text("主 Agent").font(.system(size: 11,weight: .semibold)) }.foregroundStyle(palette.accent)
                                        Text(main.name).font(.system(size: 19,weight: .bold)).foregroundStyle(palette.ink).lineLimit(1)
                                        Text("随时回到这里").font(.system(size: 12)).foregroundStyle(palette.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.accessibilityLabel("打开主 Agent " + main.name)
                            Button(action: chooseMain) { WorkspaceGlyph("more").foregroundStyle(palette.muted).frame(width: 44,height: 50) }.accessibilityLabel("更换主 Agent")
                        }.padding(.leading,14).padding(.trailing,8).padding(.vertical,14).workspaceGlass(palette,radius: 20).padding(.bottom,22)
                    }
                    WorkspaceSearch(query: $query,showing: $searching,prompt: "搜索会话或 Agent",palette: palette)
                    WorkspaceSection(title: query.isEmpty ? "最近会话" : "搜索结果",palette: palette) { Text("\(topics.count)").font(.system(size: 12)) }
                    ForEach(topics) { topic in
                        TopicActions(topic: topic,model: model) {
                            Button { openTopic(topic) } label: {
                                HStack(spacing: 12) {
                                    ContactAvatar(name: name(topic),image: image(topic),kind: topic.ownerType == "group" ? .group : .agent,size: 44)
                                    VStack(alignment: .leading,spacing: 4) {
                                        Text(topic.title).font(.system(size: 15,weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                                        Text(name(topic) + (model.rooms[topic.id]?.busy == true ? " · 正在回复" : "")).font(.system(size: 13)).foregroundStyle(palette.muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    VStack(alignment: .trailing,spacing: 9) { Text(date(topic)).font(.system(size: 11)).foregroundStyle(palette.muted); if model.rooms[topic.id]?.busy == true { Circle().fill(palette.accent).frame(width: 6,height: 6).accessibilityLabel("正在回复") }; if model.topicStates[topic.id]?.unread == true || topic.unread == true { Circle().fill(.red).frame(width: 8,height: 8).accessibilityLabel("未读主动消息") } }
                                }.padding(13).contentShape(RoundedRectangle(cornerRadius: 15))
                            }
                        }.workspaceGlass(palette,radius: 15,soft: true).padding(.bottom,8)
                    }
                    if topics.isEmpty { ContentUnavailableView(query.isEmpty ? "开始一段新对话" : "没有找到会话",systemImage: "magnifyingglass",description: Text(query.isEmpty ? "选择一个 Agent，聊聊你正在想的事。" : "试试 Agent 名字或会话标题")) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.buttonStyle(WorkspacePress()).workspaceRootNavigation().background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .task(id: model.topics) { do { let rows = try await model.store?.conversationSummaries() ?? []; summaries = Dictionary(uniqueKeysWithValues: rows.map { ($0.topicID,$0) }); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func name(_ topic: ChatTopic) -> String { model.agents.first { $0.id == topic.ownerId }?.name ?? model.groups.first { $0.id == topic.ownerId }?.name ?? "已删除的联系人" }
    private func image(_ topic: ChatTopic) -> String { model.agents.first { $0.id == topic.ownerId }?.avatarUrl ?? model.groups.first { $0.id == topic.ownerId }?.avatarUrl ?? "" }
    private func date(_ topic: ChatTopic) -> String { let value = Date(timeIntervalSince1970: topic.updatedAt); return Calendar.current.isDateInToday(value) ? value.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "zh_CN"))) : value.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))) }
}
struct WorkspaceActivityButton: View {
    let model: ChatViewModel
    var action: () -> Void
    private var count: Int { model.activity.pending.isEmpty ? model.activity.unread : model.activity.pending.count }
    var body: some View { WorkspaceIconButton(icon: "bell",label: "打开通知中心" + (count > 0 ? "，\(count) 条" + (model.activity.pending.isEmpty ? "未读" : "待审批") : ""),action: action).overlay(alignment: .topTrailing) { if count > 0 { Text(count > 99 ? "99+" : String(count)).font(.system(size: 9,weight: .bold)).foregroundStyle(.black).padding(.horizontal,4).frame(minWidth: 16,minHeight: 16).background(model.activity.pending.isEmpty ? model.appearance.theme.tint : .orange,in: Capsule()).allowsHitTesting(false) } } }
}
struct WorkspaceOwnerPicker: View {
    let model: ChatViewModel
    var mainOnly = false
    var selectAgent: (VCPAgent) -> Void
    var selectGroup: (VCPGroup) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        WorkspacePanel(title: mainOnly ? "更换主 Agent" : "新建会话",palette: palette,close: { dismiss() }) {
            LazyVStack(spacing: 0) {
                ForEach(model.agents) { agent in Button { selectAgent(agent); dismiss() } label: { HStack(spacing: 12) { ContactAvatar(name: agent.name,image: agent.avatarUrl,size: 44); VStack(alignment: .leading,spacing: 4) { Text(agent.name).foregroundStyle(palette.ink); Text(agent.description.isEmpty ? agent.model : agent.description).font(.caption).foregroundStyle(palette.muted) }; Spacer(); if mainOnly,agent.id == model.profile.mainAgentID { WorkspaceGlyph("check").foregroundStyle(palette.accent) } }.padding(.vertical,14).contentShape(Rectangle()) }; WorkspaceSeparator(palette: palette) }
                if !mainOnly { ForEach(model.groups) { group in Button { selectGroup(group); dismiss() } label: { HStack(spacing: 12) { ContactAvatar(name: group.name,image: group.avatarUrl,kind: .group,size: 44); Text(group.name); Spacer(); Text("\(group.memberIds.count) 位 Agent").font(.caption).foregroundStyle(palette.muted) }.padding(.vertical,14).contentShape(Rectangle()) } } }
            }
        } footer: { Button("取消") { dismiss() }.workspaceAction(palette) }.frame(minWidth: 340,minHeight: 400)
    }
}
