import SwiftUI

struct MeHome: View {
    let model: ChatViewModel
    var navigate: (WorkspaceView.MeScreen) -> Void
    var settings: () -> Void
    private var palette: WorkspacePalette { WorkspacePalette(theme: model.appearance.theme) }
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button { navigate(.profile) } label: {
                    HStack(spacing: 18) {
                        ContactAvatar(name: model.profile.name.isEmpty ? "我" : model.profile.name,image: model.profile.avatar,kind: .personal,size: 66)
                        VStack(alignment: .leading,spacing: 10) {
                            Text(model.profile.name.isEmpty ? "设置你的名字" : model.profile.name).font(.system(size: 23,weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("个人资料与头像").font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right").font(.system(size: 14,weight: .semibold)).foregroundStyle(.tertiary)
                    }.padding(.horizontal,24).padding(.top,35).padding(.bottom,32).frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).background(palette.surface)
                VStack(spacing: 0) {
                    row("笔记",icon: "note.text",color: .orange,screen: .notes)
                    WorkspaceSeparator(palette: palette,inset: 60)
                    row("文件",icon: "folder",color: .blue,screen: .files)
                }.background(palette.surface)
                VStack(spacing: 0) {
                    row("会话同步",icon: "arrow.triangle.2.circlepath",color: palette.accent,screen: .sync)
                    WorkspaceSeparator(palette: palette,inset: 60)
                    row("通知与监视",icon: "bell",color: .orange,detail: model.activity.unread > 0 ? "\(model.activity.unread)" : "",screen: .activity)
                }.background(palette.surface)
                Button(action: settings) { WorkspaceMenuRow(title: "设置",icon: "gearshape",color: .secondary) }.buttonStyle(.plain).background(palette.surface)
            }.padding(.top,12)
        }.background(palette.canvas.ignoresSafeArea()).workspaceRootNavigation()
    }
    private func row(_ title: String,icon: String,color: Color,detail: String = "",screen: WorkspaceView.MeScreen) -> some View {
        Button { navigate(screen) } label: { WorkspaceMenuRow(title: title,icon: icon,color: color,detail: detail) }.buttonStyle(.plain)
    }
}
