import SwiftUI
import VChatRendering
import VChatCore

struct ContactsHome: View {
    let model: ChatViewModel
    @Binding var searching: Bool
    @Binding var query: String
    var openAgent: (VCPAgent) -> Void
    var editAgent: (VCPAgent) -> Void
    var openGroup: (VCPGroup) -> Void
    var editGroup: (VCPGroup) -> Void
    var newAgent: () -> Void
    var newGroup: () -> Void
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private var agents: [VCPAgent] { model.agents.filter { query.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(query) }.sorted { if ($0.id == model.profile.mainAgentID) != ($1.id == model.profile.mainAgentID) { return $0.id == model.profile.mainAgentID }; return $0.createdAt < $1.createdAt } }
    private var groups: [VCPGroup] { model.groups.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "通讯录",subtitle: "你的 AI 伙伴",palette: palette) { WorkspaceIconButton(icon: "plus",label: "添加 Agent",accent: true,action: newAgent) }
            ScrollView {
                VStack(spacing: 0) {
                    WorkspaceSearch(query: $query,showing: $searching,prompt: "找到你的 Agent",palette: palette)
                    WorkspaceSection(title: "我的 Agent",palette: palette) { Text("\(agents.count)").font(.system(size: 12)) }
                    LazyVStack(spacing: 0) {
                        ForEach(agents) { agent in
                            HStack(spacing: 4) {
                                Button { openAgent(agent) } label: {
                                    HStack(spacing: 12) {
                                        ContactAvatar(name: agent.name,image: agent.avatarUrl,size: 44)
                                        VStack(alignment: .leading,spacing: 4) {
                                            HStack(spacing: 6) { Text(agent.name).font(.system(size: 15,weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1); if agent.id == model.profile.mainAgentID { Text("主 Agent").font(.system(size: 10,weight: .semibold)).foregroundStyle(palette.accent).padding(.horizontal,6).padding(.vertical,2).background(palette.accent.opacity(0.11),in: RoundedRectangle(cornerRadius: 6)) } }
                                            Text(agent.description.isEmpty ? (agent.model.isEmpty ? "使用默认模型" : agent.model) : agent.description).font(.system(size: 13)).foregroundStyle(palette.muted).lineLimit(1)
                                        }; Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }
                                Button { editAgent(agent) } label: { WorkspaceGlyph("more").foregroundStyle(palette.muted).frame(width: 44,height: 44) }.accessibilityLabel("编辑 " + agent.name)
                            }.padding(.horizontal,12).padding(.vertical,15)
                            if agent.id != agents.last?.id { WorkspaceSeparator(palette: palette) }
                        }
                    }.workspaceGlass(palette)
                    WorkspaceSection(title: "群聊",palette: palette) { Button(action: newGroup) { HStack(spacing: 5) { WorkspaceGlyph("plus",size: 16); Text("创建群聊").font(.system(size: 14)) }.foregroundStyle(palette.accent).frame(minHeight: 32) } }
                    if groups.isEmpty { Text("让不同的 Agent 在同一个会话里交流。").font(.system(size: 14)).foregroundStyle(palette.muted).frame(maxWidth: .infinity,alignment: .leading) }
                    else { LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            HStack(spacing: 4) {
                                Button { openGroup(group) } label: { HStack(spacing: 12) { ContactAvatar(name: group.name,image: group.avatarUrl,kind: .group,size: 44); VStack(alignment: .leading,spacing: 4) { Text(group.name).font(.system(size: 15,weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1); Text("\(group.memberIds.count) 位 Agent · \(group.mode.title)").font(.system(size: 13)).foregroundStyle(palette.muted).lineLimit(1) }; Spacer(minLength: 0) }.contentShape(Rectangle()) }
                                Button { editGroup(group) } label: { WorkspaceGlyph("more").foregroundStyle(palette.muted).frame(width: 44,height: 44) }.accessibilityLabel("编辑群聊 " + group.name)
                            }.padding(.horizontal,12).padding(.vertical,15)
                            if group.id != groups.last?.id { WorkspaceSeparator(palette: palette) }
                        }
                    }.workspaceGlass(palette) }
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }.buttonStyle(WorkspacePress()).workspaceRootNavigation().background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
    }
}
