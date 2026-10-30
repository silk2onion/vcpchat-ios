import SwiftUI
import VChatCore

struct TopicsView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var rename: ChatTopic?
    @State private var title = ""
    @State private var deleting: ChatTopic?
    var topics: [ChatTopic] {
        model.topics.filter { $0.ownerId == model.activeTopic?.ownerId && $0.ownerType == model.activeTopic?.ownerType }.sorted { $0.updatedAt > $1.updatedAt }
    }
    var body: some View {
        NavigationStack {
            List {
                ForEach(topics) { topic in
                    HStack {
                        Button { Task { await model.openTopic(topic); dismiss() } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(topic.title).foregroundStyle(.primary)
                                Text(Date(timeIntervalSince1970: topic.updatedAt), style: .date).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if model.rooms[topic.id]?.busy == true { ProgressView().controlSize(.small) }
                        if model.activeTopicID == topic.id { Image(systemName: "checkmark").foregroundStyle(.mint) }
                        Menu {
                            Button("重命名", systemImage: "pencil") { title = topic.title; rename = topic }
                            Button("删除对话", systemImage: "trash", role: .destructive) { deleting = topic }
                        } label: { Image(systemName: "ellipsis").frame(width: 38, height: 44) }.menuStyle(.borderlessButton)
                    }
                }
            }.navigationTitle("历史话题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("新话题", systemImage: "plus") { Task { if let topic = model.activeTopic { await model.createTopic(ownerID: topic.ownerId, ownerType: topic.ownerType); dismiss() } } } }
            }
            .alert("重命名话题", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
                TextField("话题名", text: $title)
                Button("取消", role: .cancel) { rename = nil }
                Button("保存") { if let topic = rename { Task { await model.renameTopic(topic, title: title) } }; rename = nil }
            }
            .confirmationDialog("删除这段对话及其消息？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除对话", role: .destructive) { if let topic = deleting { Task { await model.removeTopic(topic) } }; deleting = nil }
            }
        }.frame(minWidth: 340, minHeight: 450)
    }
}
