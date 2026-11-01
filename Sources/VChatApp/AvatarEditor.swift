import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering

struct AvatarEditor: View {
    @Binding var image: String
    let name: String
    var kind = ContactAvatar.Kind.agent
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceTheme) private var theme
    @State private var picker: PhotosPickerItem?
    @State private var importing = false
    @State private var preview = ""
    @State private var ready = false
    @State private var animated = false
    @State private var zoom = 1.0
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var error: String?
    @State private var processor = AvatarProcessor()
    var body: some View {
        let palette = WorkspacePalette(theme: theme)
        WorkspacePanel(title: "编辑头像",palette: palette,close: { dismiss() }) {
            VStack(spacing: 22) {
                ContactAvatar(name: name,image: preview.isEmpty ? image : preview,kind: kind,size: 220).padding(.top,12)
                HStack { PhotosPicker(selection: $picker,matching: .images) { Label("照片",systemImage: "photo") }; Button("从文件选择",systemImage: "folder") { importing = true } }.foregroundStyle(palette.accent).frame(minHeight: 44)
                if animated { Text("动态头像保留完整动画，按头像区域居中显示。").font(.caption).foregroundStyle(palette.muted) }
                if ready && !animated {
                    VStack(alignment: .leading,spacing: 16) {
                        Text("缩放").font(.caption); Slider(value: $zoom,in: 1...4)
                        Text("左右位置").font(.caption); Slider(value: $x,in: -1...1)
                        Text("上下位置").font(.caption); Slider(value: $y,in: -1...1)
                    }
                }
                if !image.isEmpty { Button("移除头像",role: .destructive) { image = ""; dismiss() } }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }.frame(maxWidth: .infinity)
        } footer: { HStack(spacing: 10) { Button("取消") { dismiss() }.workspaceAction(palette); Button("使用") { if !preview.isEmpty { image = preview }; dismiss() }.workspaceAction(palette,primary: true).disabled(preview.isEmpty) } }
        .onChange(of: picker) { _, item in
                Task {
                    do { if let data = try await item?.loadTransferable(type: Data.self) { try await processor.prepare(data: data); await prepared() } }
                    catch { self.error = "无法读取照片" }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { Task { do { try await processor.prepare(url: url); await prepared() } catch { self.error = error.localizedDescription } } }
            }
            .task(id: "\(zoom):\(x):\(y):\(ready)") {
                guard ready && !animated else { return }
                do { try await Task.sleep(for: .milliseconds(70)); let value = try await processor.crop(zoom: zoom, x: x, y: y); if !Task.isCancelled { preview = value } }
                catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
        .frame(minWidth: 340, minHeight: 580)
    }
    func prepared() async {
        animated = await processor.isAnimated
        zoom = 1; x = 0; y = 0
        do { preview = try await processor.crop(zoom: 1, x: 0, y: 0); ready = true; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
struct ProfileEditor: View {
    @Bindable var model: ChatViewModel
    @State var profile: UserProfile
    @State private var avatar = false
    @Environment(\.dismiss) private var dismiss
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            WorkspaceDetailHeader(title: "个人资料",palette: palette,note: "本机保存") { EmptyView() }
            #endif
            ScrollView { VStack(alignment: .leading,spacing: 24) {
                Button { avatar = true } label: { HStack(spacing: 18) { ContactAvatar(name: "我",image: profile.avatar,kind: .personal,size: 88); VStack(alignment: .leading,spacing: 6) { Text("编辑我的头像").font(.system(size: 16,weight: .semibold)); Text("选择照片或图片，自由调整裁剪").font(.system(size: 13)).foregroundStyle(palette.muted) }; Spacer(); WorkspaceGlyph("chevron",size: 18) }.padding(.vertical,8).contentShape(Rectangle()) }
                WorkspaceField(title: "你的名字",palette: palette) { TextField("你的名字",text: $profile.name) }
                Button("保存") { Task { if await model.saveProfile(profile) { dismiss() } } }.workspaceAction(palette,primary: true)
                NavigationLink { RemoteNotesView(model: model).workspaceDetailNavigation() } label: { WorkspaceMenuRow(title: "服务器日记账号",icon: "notes",color: palette.accent,subtitle: "管理员连接与服务器日记") }.workspaceGlass(palette)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity) }
        }.workspacePageNavigation(title: "个人资料",palette: palette,note: "本机保存").buttonStyle(WorkspacePress()).background(VChatRendering.ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea())
        .sheet(isPresented: $avatar) { AvatarEditor(image: $profile.avatar,name: profile.name.isEmpty ? "我" : profile.name,kind: .personal) }
    }
}
