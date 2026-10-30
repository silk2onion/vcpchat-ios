import SwiftUI
import VChatCore

struct GroupEditor: View {
    @Bindable var model: ChatViewModel
    @State var group: VCPGroup
    @State private var avatar = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var existing: Bool { model.groups.contains { $0.id == group.id } }
    var body: some View {
        NavigationStack {
            Form {
                Section("群聊资料") {
                    Button { avatar = true } label: { HStack { ContactAvatar(name: group.name, image: group.avatarUrl, kind: .group, size: 62); Spacer(); Label("编辑头像", systemImage: "camera") } }.buttonStyle(.plain)
                    TextField("群聊名称", text: $group.name)
                    Picker("发言方式", selection: $group.mode) { ForEach(GroupMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("统一模型（留空使用各成员的模型）", text: $group.unifiedModel)
                }
                Section("群组系统提示词") { TextEditor(text: $group.systemPrompt).frame(minHeight: 100) }
                Section("群成员") {
                    ForEach(model.agents) { agent in
                        Toggle(isOn: Binding(get: { group.memberIds.contains(agent.id) }, set: { selected in
                            if selected { group.memberIds.append(agent.id) } else { group.memberIds.removeAll { $0 == agent.id } }
                        })) { Text(agent.name) }
                    }
                }
                if group.memberIds.count > 1 {
                    Section("发言顺序") {
                        ForEach(Array(group.memberIds.enumerated()), id: \.element) { index, id in
                            HStack {
                                Text("\(index + 1). \(model.agents.first { $0.id == id }?.name ?? "已删除的成员")")
                                Spacer()
                                Button { group.memberIds.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).buttonStyle(.borderless).accessibilityLabel("上移成员")
                            }
                        }
                    }
                }
                if existing { Section { Button("删除群聊", role: .destructive) { deleting = true } } }
            }.formStyle(.grouped).navigationTitle(existing ? "编辑群聊" : "创建群聊")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { if await model.saveGroup(group) { dismiss() } } }.disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.memberIds.isEmpty) }
            }
            .sheet(isPresented: $avatar) { AvatarEditor(image: $group.avatarUrl, name: group.name) }
            .confirmationDialog("删除群聊？聊天记录将保留。", isPresented: $deleting, titleVisibility: .visible) { Button("删除群聊", role: .destructive) { Task { await model.removeGroup(group.id); dismiss() } } }
        }.frame(minWidth: 340, minHeight: 600)
    }
}
