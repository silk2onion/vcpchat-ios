import SwiftUI
import VChatCore

struct DiscoverView: View {
    enum Screen: Hashable { case notifications,log,rag,memory }
    let model: ChatViewModel
    @Binding var atRoot: Bool
    @State private var path: [Screen] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var palette: WorkspacePalette { WorkspacePalette(theme: model.appearance.theme) }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                WorkspaceHeader(title: "发现",palette: palette) { EmptyView() }
                ScrollView {
                    VStack(spacing: 8) {
                        WorkspaceMenuRow(title: "VCP 论坛",icon: "bubble.left.and.bubble.right",color: .orange,detail: "后续接入",chevron: false).background(palette.surface)
                        VStack(spacing: 0) {
                            row("VCP 记忆",icon: "brain.head.profile",color: .purple,screen: .memory)
                            WorkspaceSeparator(palette: palette,inset: 60)
                            row("RAG 监视器",icon: "cylinder.split.1x2",color: .blue,screen: .rag)
                        }.background(palette.surface)
                        VStack(spacing: 0) {
                            row("通知与审批",icon: "bell",color: .orange,detail: model.activity.unread > 0 ? "\(model.activity.unread)" : "",screen: .notifications)
                            WorkspaceSeparator(palette: palette,inset: 60)
                            row("VCPLog",icon: "waveform.path",color: palette.accent,screen: .log)
                        }.background(palette.surface)
                        Text("记忆入口当前展示 VCP 推送的检索动态。").font(.system(size: 13)).foregroundStyle(.tertiary).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,18).padding(.top,6)
                    }.padding(.top,8)
                }
            }.background(palette.canvas.ignoresSafeArea()).workspaceRootNavigation()
            .navigationDestination(for: Screen.self) { screen in
                Group {
                    switch screen {
                    case .notifications: ActivityView(model: model)
                    case .log: ActivityView(model: model,initialSection: 1)
                    case .rag: ActivityView(model: model,initialSection: 2)
                    case .memory: ActivityView(model: model,initialSection: 2,initialFilter: .memory)
                    }
                }.workspaceDetailNavigation()
            }
        }.onChange(of: path) { _,value in atRoot = value.isEmpty }
        .onAppear { atRoot = path.isEmpty }
    }
    private func row(_ title: String,icon: String,color: Color,detail: String = "",screen: Screen) -> some View {
        Button { withAnimation(model.renderOptions.motion && !reduceMotion ? .easeInOut(duration: 0.22) : nil) { path.append(screen) } } label: { WorkspaceMenuRow(title: title,icon: icon,color: color,detail: detail) }.buttonStyle(.plain)
    }
}
