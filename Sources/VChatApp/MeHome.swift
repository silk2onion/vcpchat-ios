import SwiftUI
import VChatRendering

struct MeHome: View {
    let model: ChatViewModel
    var navigate: (WorkspaceView.MeScreen) -> Void
    var avatar: () -> Void
    var activity: () -> Void
    var settings: () -> Void
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(title: "我",palette: palette) { EmptyView() }
            ScrollView {
                VStack(spacing: 22) {
                    HStack(spacing: 17) {
                        Button(action: avatar) {
                            ContactAvatar(name: "我",image: model.profile.avatar,kind: .personal,size: 64).overlay(alignment: .bottomTrailing) { WorkspaceGlyph("camera",size: 14).foregroundStyle(palette.accentInk).frame(width: 24,height: 24).background(palette.accent,in: Circle()).overlay(Circle().stroke(palette.solid,lineWidth: 2)).offset(x: 3,y: 3) }
                        }.accessibilityLabel("编辑我的头像")
                        Button { navigate(.profile) } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading,spacing: 7) { Text(model.profile.name.isEmpty ? "设置你的名字" : model.profile.name).font(.system(size: 24,weight: .bold)).foregroundStyle(palette.ink).lineLimit(2); Text("个人资料与日记身份").font(.system(size: 13)).foregroundStyle(palette.muted) }
                                Spacer(minLength: 4); WorkspaceGlyph("chevron",size: 20).foregroundStyle(palette.muted)
                            }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                        }
                    }.padding(.horizontal,4).padding(.top,24).padding(.bottom,28)
                    VStack(spacing: 0) {
                        row("桌面同步",icon: "sync",color: palette.accent,subtitle: "会话、Agent 与群组",screen: .sync)
                        WorkspaceSeparator(palette: palette)
                        row("文件",icon: "folder",color: Color(rgb: 0x71a8d5),subtitle: "连接文件夹、本机与服务器",screen: .files)
                        WorkspaceSeparator(palette: palette)
                        row("笔记",icon: "notes",color: Color(rgb: 0x71a8d5),subtitle: "本机笔记与服务器日记",screen: .notes)
                        WorkspaceSeparator(palette: palette)
                        Button(action: activity) { WorkspaceMenuRow(title: "通知中心",icon: "bell",color: Color(rgb: 0xad93db),subtitle: "待审批、VCPLog 与 RAG",detail: model.activity.unread > 0 ? String(model.activity.unread) : "") }
                    }.workspaceGlass(palette)
                    Button(action: settings) { WorkspaceMenuRow(title: "设置",icon: "settings",color: palette.accent,subtitle: "连接、外观与使用习惯") }.workspaceGlass(palette)
                }.padding(.horizontal,20).padding(.bottom,28).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
        }.buttonStyle(WorkspacePress()).workspaceRootNavigation().background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
    }
    private func row(_ title: String,icon: String,color: Color,subtitle: String,screen: WorkspaceView.MeScreen) -> some View { Button { navigate(screen) } label: { WorkspaceMenuRow(title: title,icon: icon,color: color,subtitle: subtitle) } }
}
