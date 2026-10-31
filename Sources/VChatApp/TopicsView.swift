import SwiftUI
import VChatCore

struct TopicsView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    var topics: [ChatTopic] {
        model.topics.filter { $0.ownerId == model.activeTopic?.ownerId && $0.ownerType == model.activeTopic?.ownerType }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(topics) { topic in
                    TopicActions(topic: topic,model: model,showsMenu: true) {
                        HStack {
                            Button { Task { await model.openTopic(topic); dismiss() } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(topic.title).foregroundStyle(.primary)
                                    Text(Date(timeIntervalSince1970: topic.updatedAt), style: .date).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if model.rooms[topic.id]?.busy == true { ProgressView().controlSize(.small) }
                            if model.activeTopicID == topic.id { Image(systemName: "checkmark").foregroundStyle(.mint) }
                        }
                    }
                }
            }.navigationTitle("历史话题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新话题", systemImage: "plus") { Task { if let topic = model.activeTopic { await model.createTopic(ownerID: topic.ownerId, ownerType: topic.ownerType); dismiss() } } } }
            }
        }.frame(minWidth: 340, minHeight: 450)
    }
}

/// Keep long-press and visible menu actions on the same row-owned presentation state.
struct TopicActions<Content: View>: View {
    let topic: ChatTopic
    let model: ChatViewModel
    var showsMenu = false
    @ViewBuilder var content: Content
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false
    var body: some View {
        HStack(spacing: 0) {
            content
            if showsMenu {
                Menu { menuItems } label: { Image(systemName: "ellipsis").frame(width: 44,height: 44) }
                    .accessibilityLabel("会话操作")
            }
        }
        .contextMenu { menuItems }
        .alert("重命名话题", isPresented: $renaming) {
            TextField("话题名", text: $title)
            Button("取消", role: .cancel) {}
            Button("保存") { Task { await model.renameTopic(topic,title: title) } }
                .disabled(model.synchronizing || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("删除这段对话及其消息？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除对话", role: .destructive) { Task { await model.removeTopic(topic) } }.disabled(model.synchronizing)
            Button("取消", role: .cancel) {}
        } message: { Text("这会删除本机的对话和消息，无法撤销。") }
    }
    @ViewBuilder private var menuItems: some View {
        Button("重命名", systemImage: "pencil") { title = topic.title; renaming = true }.disabled(model.synchronizing)
        Button("删除对话", systemImage: "trash", role: .destructive) { deleting = true }.disabled(model.synchronizing)
    }
}
