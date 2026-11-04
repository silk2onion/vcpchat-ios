import SwiftUI
import VChatCore

struct GroupEditor: View {
    @Bindable var model: ChatViewModel
    @State var group: VCPGroup
    @State private var avatar = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var existing: Bool { model.groups.contains { $0.id == group.id } }
    var body: some View {
        WorkspacePanel(title: existing ? "群聊资料" : "创建群聊",palette: palette,close: { dismiss() }) {
            VStack(alignment: .leading,spacing: 24) {
                Button { avatar = true } label: { HStack(spacing: 18) { ContactAvatar(name: group.name,image: group.avatarUrl,kind: .group,size: 72); Label("编辑头像",systemImage: "camera").foregroundStyle(palette.accent); Spacer() }.contentShape(Rectangle()) }
                WorkspaceField(title: "群聊名称",palette: palette) { TextField("群聊名称",text: $group.name) }
                WorkspaceField(title: "发言方式",palette: palette) { Picker("发言方式",selection: $group.mode) { ForEach(GroupMode.allCases,id: \.self) { Text($0.title).tag($0) } }.labelsHidden() }
                WorkspaceModelField(model: model,selection: $group.unifiedModel,title: "统一模型",prompt: "留空使用各成员的模型")
                WorkspaceField(title: "群组系统提示词",palette: palette) { TextEditor(text: $group.systemPrompt).scrollContentBackground(.hidden).frame(minHeight: 100).accessibilityLabel("群组系统提示词") }
                VStack(alignment: .leading,spacing: 14) {
                    Toggle("只发送最近的群聊消息",isOn: Binding(get: { group.enableContextMessageWindow == true },set: { group.enableContextMessageWindow = $0 }))
                    if group.enableContextMessageWindow == true {
                        WorkspaceField(title: "消息条数（1–10000）",palette: palette) { TextField("100",value: $group.contextMessageWindowSize,format: .number.grouping(.never)).accessibilityLabel("群聊历史消息条数") }
                        Text("启用后，较早消息不再发送，窗口每轮移动，也会改变历史缓存前缀。条数按消息计，不是对话轮次；留空为 100。").font(.caption).foregroundStyle(palette.muted)
                    } else { Text("默认发送完整群聊历史，不自动截断。").font(.caption).foregroundStyle(palette.muted) }
                }
                VStack(alignment: .leading,spacing: 14) {
                    Text("群成员").font(.system(size: 14)).foregroundStyle(palette.muted)
                    ForEach(model.agents) { agent in
                        Toggle(isOn: Binding(get: { group.memberIds.contains(agent.id) },set: { selected in if selected { group.memberIds.append(agent.id) } else { group.memberIds.removeAll { $0 == agent.id } } })) { HStack(spacing: 12) { ContactAvatar(name: agent.name,image: agent.avatarUrl,size: 35); Text(agent.name).font(.system(size: 15)) } }.toggleStyle(.switch)
                    }
                }
                if group.memberIds.count > 1 {
                    VStack(alignment: .leading,spacing: 14) {
                        Text("发言顺序").font(.system(size: 14)).foregroundStyle(palette.muted)
                        ForEach(Array(group.memberIds.enumerated()),id: \.element) { index,id in HStack { Text("\(index + 1). \(model.agents.first { $0.id == id }?.name ?? "已删除的成员")"); Spacer(); Button { group.memberIds.swapAt(index,index - 1) } label: { WorkspaceGlyph("up",size: 18).frame(width: 40,height: 40) }.disabled(index == 0).accessibilityLabel("上移成员") } }
                    }
                }
                if existing { Button("删除群聊",role: .destructive) { deleting = true } }
            }
        } footer: { HStack(spacing: 10) { Button("取消") { dismiss() }.workspaceAction(palette); Button("保存") { Task { if await model.saveGroup(group) { dismiss() } } }.workspaceAction(palette,primary: true).disabled(group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.memberIds.isEmpty || (group.enableContextMessageWindow == true && !(1...10_000).contains(group.contextMessageWindowSize ?? 100))) } }
        .frame(minWidth: 340,minHeight: 600)
        .sheet(isPresented: $avatar) { AvatarEditor(image: $group.avatarUrl,name: group.name,kind: .group) }
        .confirmationDialog("删除群聊？聊天记录将保留。",isPresented: $deleting,titleVisibility: .visible) { Button("删除群聊",role: .destructive) { Task { await model.removeGroup(group.id); dismiss() } } }
    }
}
