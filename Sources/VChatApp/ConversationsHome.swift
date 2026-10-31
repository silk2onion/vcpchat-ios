import SwiftUI
import VChatCore

struct ConversationsHome: View {
    let model: ChatViewModel
    @Binding var searching: Bool
    @Binding var query: String
    var openAgent: (VCPAgent) -> Void
    var openTopic: (ChatTopic) -> Void
    var newAgent: () -> Void
    var newGroup: () -> Void
    var contacts: () -> Void
    @State private var summaries: [String:ConversationSummary] = [:]
    @State private var error: String?
    private var palette: WorkspacePalette { WorkspacePalette(theme: model.appearance.theme) }
    private var ordered: [ChatTopic] { model.topics.sorted { $0.updatedAt > $1.updatedAt } }
    private var pinned: ChatTopic? { ordered.first { $0.ownerType == "agent" && $0.ownerId == model.mainAgent?.id } }
    private var filtered: [ChatTopic] {
        ordered.filter { topic in
            if !searching { return topic.id != pinned?.id }
            if query.isEmpty { return true }
            return (name(topic) + " " + topic.title + " " + (summaries[topic.id]?.display ?? "")).localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            if searching { WorkspaceSearch(query: $query,showing: $searching,prompt: "搜索会话",palette: palette) }
            else { WorkspaceHeader(title: "会话",palette: palette) {
                Button { searching = true } label: { Image(systemName: "magnifyingglass").frame(width: 44,height: 44) }.accessibilityLabel("搜索会话")
                Menu {
                    Button("发起对话",systemImage: "bubble.left.and.bubble.right") { contacts() }
                    Button("添加 Agent",systemImage: "person.badge.plus") { newAgent() }
                    Button("创建群聊",systemImage: "person.2.badge.plus") { newGroup() }
                } label: { Image(systemName: "plus.circle").frame(width: 44,height: 44) }.accessibilityLabel("新对话菜单")
            } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !searching,let main = model.mainAgent {
                        Button { openAgent(main) } label: {
                            ConversationRow(name: main.name,image: main.avatarUrl,symbol: main.avatar,group: false,preview: pinned.map(preview) ?? "开始和主 Agent 对话",date: pinned.map(date) ?? "",pinned: true,busy: pinned.map { model.rooms[$0.id]?.busy == true } ?? false)
                        }.buttonStyle(.plain).background(palette.pinned)
                        WorkspaceSeparator(palette: palette)
                    }
                    ForEach(filtered) { topic in
                        Button { openTopic(topic) } label: {
                            ConversationRow(name: name(topic),image: image(topic),symbol: symbol(topic),group: topic.ownerType == "group",preview: preview(topic),date: date(topic),pinned: false,busy: model.rooms[topic.id]?.busy == true)
                        }.buttonStyle(.plain).background(palette.surface)
                        WorkspaceSeparator(palette: palette)
                    }
                    if searching,filtered.isEmpty { ContentUnavailableView("没有找到会话",systemImage: "magnifyingglass") }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
                }
            }.scrollDismissesKeyboard(.interactively)
        }.background(palette.canvas.ignoresSafeArea()).workspaceRootNavigation()
        .task(id: model.topics) { await refresh() }
    }
    private func refresh() async {
        do { let rows = try await model.store?.conversationSummaries() ?? []; summaries = Dictionary(uniqueKeysWithValues: rows.map { ($0.topicID,$0) }); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func name(_ topic: ChatTopic) -> String { model.agents.first { $0.id == topic.ownerId }?.name ?? model.groups.first { $0.id == topic.ownerId }?.name ?? "已删除的联系人" }
    private func image(_ topic: ChatTopic) -> String { model.agents.first { $0.id == topic.ownerId }?.avatarUrl ?? model.groups.first { $0.id == topic.ownerId }?.avatarUrl ?? "" }
    private func symbol(_ topic: ChatTopic) -> String { model.agents.first { $0.id == topic.ownerId }?.avatar ?? "" }
    private func preview(_ topic: ChatTopic) -> String {
        let subject = ["新对话","第一段对话"].contains(topic.title) ? "" : topic.title
        if model.rooms[topic.id]?.busy == true { return [subject,"正在回复…"].filter { !$0.isEmpty }.joined(separator: " · ") }
        guard let summary = summaries[topic.id],!summary.display.isEmpty else { return subject.isEmpty ? "开始一段对话" : subject }
        let author = topic.ownerType == "group" && !summary.authorName.isEmpty ? summary.authorName + "：" : ""
        return [subject,author + summary.display].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func date(_ topic: ChatTopic) -> String {
        let value = Date(timeIntervalSince1970: summaries[topic.id]?.createdAt ?? topic.updatedAt)
        if Calendar.current.isDateInToday(value) { return value.formatted(.dateTime.hour().minute()) }
        if Calendar.current.isDateInYesterday(value) { return "昨天" }
        return value.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}
private struct ConversationRow: View {
    let name: String; let image: String; let symbol: String; let group: Bool
    let preview: String; let date: String; let pinned: Bool; let busy: Bool
    var body: some View {
        HStack(spacing: 12) {
            ContactAvatar(name: name,image: image,symbol: symbol,kind: group ? .group : .agent,size: 48)
            VStack(alignment: .leading,spacing: 7) {
                HStack(alignment: .firstTextBaseline,spacing: 8) {
                    Text(name).font(.system(size: 17,weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(date).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(preview).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                    else if pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityLabel("主 Agent") }
                }
            }
        }.padding(.horizontal,16).padding(.vertical,13).contentShape(Rectangle())
    }
}
