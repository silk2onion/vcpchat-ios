import SwiftUI
import VChatCore

struct DiscoverView: View {
    let model: ChatViewModel
    var activity: (Int,ActivityKind) -> Void
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WorkspaceHeader(title: "发现",subtitle: "VCP 信息与记忆",palette: palette) { WorkspaceActivityButton(model: model) { activity(0,.all) } }
                ScrollView {
                    VStack(spacing: 22) {
                        WorkspaceMenuRow(title: "VCP 论坛",icon: "chat",color: palette.accent,subtitle: "社区与 Agent 的交流空间",detail: "后续接入",chevron: false).workspaceGlass(palette)
                        VStack(spacing: 0) {
                            row("VCP 记忆",icon: "brain",color: Color(rgb: 0xad93db),subtitle: "记忆检索动态",section: 2,filter: .memory)
                            WorkspaceSeparator(palette: palette)
                            row("RAG 监视器",icon: "database",color: Color(rgb: 0x71a8d5),subtitle: "知识库、元思考与 Agent 事件",section: 2)
                        }.workspaceGlass(palette)
                        VStack(spacing: 0) {
                            row("通知与审批",icon: "bell",color: Color(rgb: 0xad93db),subtitle: "需要你决定的工具调用",section: 0)
                            WorkspaceSeparator(palette: palette)
                            row("VCPLog",icon: "logs",color: palette.accent,subtitle: "实时日志与连接状态",section: 1)
                        }.workspaceGlass(palette)
                    }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }.buttonStyle(WorkspacePress()).workspaceRootNavigation()
        }
    }
    private func row(_ title: String,icon: String,color: Color,subtitle: String,section: Int,filter: ActivityKind = .all) -> some View { Button { activity(section,filter) } label: { WorkspaceMenuRow(title: title,icon: icon,color: color,subtitle: subtitle) } }
}
