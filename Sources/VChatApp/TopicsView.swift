import SwiftUI
import VChatCore

struct TopicsView: View {
    @Bindable var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        let owner = model.activeTopic
        let scope = (owner?.ownerType ?? "") + ":" + (owner?.ownerId ?? "")
        let order = model.topicOrdering
        let topics = order.sorted(model.topics.filter { $0.ownerId == owner?.ownerId && $0.ownerType == owner?.ownerType },
                                  in: scope, lastMessages: model.lastMessageTimes)
        let manual = order.isManual(scope)
        let byActivity = order.automatic == .activity
        let mode = manual ? "手动顺序" : (byActivity ? "最近对话" : "创建时间")
        let next = (manual ? byActivity : !byActivity) ? "最近对话" : "创建时间"

        NavigationStack {
            WorkspaceList {
                Section {
                    ForEach(topics) { topic in
                        let pinned = order.isPinned(topic.id, in: scope)
                        TopicActions(topic: topic, model: model, showsMenu: true, positionPinned: pinned, togglePin: {
                            if let slot = topics.firstIndex(where: { $0.id == topic.id }) {
                                model.topicOrdering.togglePin(topic.id, at: slot, in: scope)
                            }
                        }) {
                            HStack {
                                Button { Task { await model.openTopic(topic); dismiss() } } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(topic.title).foregroundStyle(.primary)
                                        let date = order.automatic.date(for: topic, lastMessage: model.lastMessageTimes[topic.id])
                                        if date > 0 { Text(Date(timeIntervalSince1970: date), style: .date).font(.caption).foregroundStyle(.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("排序位置已固定") }
                                if model.rooms[topic.id]?.busy == true { ProgressView().controlSize(.small) }
                                if model.activeTopicID == topic.id { Image(systemName: "checkmark").foregroundStyle(.mint) }
                            }
                        }.moveDisabled(pinned)
                    }.onMove { offsets, destination in
                        var moved = topics
                        moved.move(fromOffsets: offsets, toOffset: destination)
                        model.topicOrdering.saveMove(moved, replacing: topics, in: scope)
                    }
                } header: {
                    HStack {
                        Button {
                            model.topicOrdering.ring(in: scope)
                        } label: {
                            Label(mode, systemImage: manual ? "bell.slash" : (byActivity ? "bell.and.waves.left.and.right" : "bell"))
                                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }
                        .accessibilityLabel("话题排序：" + mode)
                        .accessibilityHint("切换到" + next)
                        .accessibilityIdentifier("topic-sort-bell")
                        Spacer()
                        #if os(iOS)
                        if topics.count > 1 {
                            Button(editMode.isEditing ? "收起拖柄" : "调整顺序") {
                                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                            }.font(.subheadline).frame(minHeight: 44)
                        }
                        #endif
                    }.textCase(nil)
                }
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .navigationTitle("历史话题")
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
    var positionPinned = false
    var togglePin: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false
    var body: some View {
        HStack(spacing: 0) {
            content
            if showsMenu {
                Menu { menuItems } label: { Image(systemName: "ellipsis").frame(width: 44,height: 44) }
                    .menuStyle(.borderlessButton).fixedSize()
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
        if let togglePin {
            Button(positionPinned ? "解除固定位置" : "固定排序位置", systemImage: positionPinned ? "pin.slash" : "pin", action: togglePin)
        }
        if topic.ownerType == "agent" {
            let locked = model.topicStates[topic.id]?.locked ?? topic.locked ?? true
            Button(locked ? "允许 Agent 追加回复" : "锁定 Agent 追加回复",systemImage: locked ? "lock.open" : "lock") { Task { await model.setTopicLocked(topic,locked: !locked) } }.disabled(model.synchronizing)
        }
        Button("重命名", systemImage: "pencil") { title = topic.title; renaming = true }.disabled(model.synchronizing)
        Button("删除对话", systemImage: "trash", role: .destructive) { deleting = true }.disabled(model.synchronizing)
    }
}
