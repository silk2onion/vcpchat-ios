import SwiftUI
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
    private var palette: WorkspacePalette { WorkspacePalette(theme: model.appearance.theme) }
    private var agents: [VCPAgent] {
        model.agents.filter { !searching || query.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(query) }.sorted {
            if ($0.id == model.profile.mainAgentID) != ($1.id == model.profile.mainAgentID) { return $0.id == model.profile.mainAgentID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var groups: [VCPGroup] { model.groups.filter { !searching || query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            if searching { WorkspaceSearch(query: $query,showing: $searching,prompt: "搜索 Agent 或群聊",palette: palette) }
            else { WorkspaceHeader(title: "通讯录",palette: palette) {
                Button { searching = true } label: { Image(systemName: "magnifyingglass").frame(width: 44,height: 44) }.accessibilityLabel("搜索通讯录")
                Button(action: newAgent) { Image(systemName: "person.badge.plus").frame(width: 44,height: 44) }.accessibilityLabel("添加 Agent")
            } }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !searching {
                        Button(action: newGroup) { WorkspaceMenuRow(title: "创建群聊",icon: "person.2.fill",color: .blue) }.buttonStyle(.plain).background(palette.surface)
                    }
                    section("Agent")
                    ForEach(agents) { agent in
                        HStack(spacing: 0) {
                            Button { openAgent(agent) } label: {
                                HStack(spacing: 12) {
                                    ContactAvatar(name: agent.name,image: agent.avatarUrl,symbol: agent.avatar,size: 40)
                                    VStack(alignment: .leading,spacing: 5) {
                                        Text(agent.name).font(.system(size: 17)).foregroundStyle(.primary).lineLimit(1)
                                        if !agent.description.isEmpty { Text(agent.description).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 6)
                                    if agent.id == model.profile.mainAgentID { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(.tertiary).accessibilityLabel("主 Agent") }
                                }.padding(.leading,16).padding(.vertical,10).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { editAgent(agent) } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 48,height: 56).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("编辑 " + agent.name)
                        }.background(palette.surface)
                        WorkspaceSeparator(palette: palette,inset: 68)
                    }
                    if !groups.isEmpty {
                        section("群聊")
                        ForEach(groups) { group in
                            HStack(spacing: 0) {
                                Button { openGroup(group) } label: {
                                    HStack(spacing: 12) {
                                        ContactAvatar(name: group.name,image: group.avatarUrl,kind: .group,size: 40)
                                        VStack(alignment: .leading,spacing: 5) { Text(group.name).font(.system(size: 17)).foregroundStyle(.primary).lineLimit(1); Text("\(group.memberIds.count) 位 Agent").font(.system(size: 13)).foregroundStyle(.secondary) }
                                        Spacer(minLength: 0)
                                    }.padding(.leading,16).padding(.vertical,10).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { editGroup(group) } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 48,height: 56).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("编辑群聊 " + group.name)
                            }.background(palette.surface)
                            WorkspaceSeparator(palette: palette,inset: 68)
                        }
                    }
                    if searching,agents.isEmpty,groups.isEmpty { ContentUnavailableView("没有找到联系人",systemImage: "person.crop.circle.badge.questionmark") }
                    else { Text("\(agents.count) 位 Agent · \(groups.count) 个群聊").font(.system(size: 13)).foregroundStyle(.tertiary).padding(24) }
                }
            }.scrollDismissesKeyboard(.interactively)
        }.background(palette.canvas.ignoresSafeArea()).workspaceRootNavigation()
    }
    private func section(_ name: String) -> some View { Text(name).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,16).padding(.vertical,9) }
}
