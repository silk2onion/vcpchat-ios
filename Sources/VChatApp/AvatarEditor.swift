import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VChatCore

struct AvatarEditor: View {
    @Binding var image: String
    let name: String
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            VStack(spacing: 22) {
                ContactAvatar(name: name, image: preview.isEmpty ? image : preview, size: 220).padding(.top, 20)
                HStack {
                    PhotosPicker(selection: $picker, matching: .images) { Label("照片", systemImage: "photo") }
                    Button("从文件选择", systemImage: "folder") { importing = true }
                }.buttonStyle(.bordered)
                if animated { Text("动态头像保留完整动画，按头像区域居中显示。").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if ready && !animated {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("缩放").font(.caption); Slider(value: $zoom, in: 1...4)
                        Text("左右位置").font(.caption); Slider(value: $x, in: -1...1)
                        Text("上下位置").font(.caption); Slider(value: $y, in: -1...1)
                    }.padding(.horizontal, 28)
                }
                if !image.isEmpty { Button("移除头像", role: .destructive) { image = ""; dismiss() } }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                Spacer(minLength: 0)
            }
            .navigationTitle("编辑头像")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("使用") { if !preview.isEmpty { image = preview }; dismiss() }.disabled(preview.isEmpty) }
            }
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
        }.frame(minWidth: 340, minHeight: 580)
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
    var body: some View {
        Form {
            Section {
                Button { avatar = true } label: { HStack(spacing: 15) { ContactAvatar(name: profile.name.isEmpty ? "我" : profile.name, image: profile.avatar, kind: .personal, size: 64); Text("编辑头像"); Spacer(); Image(systemName: "chevron.right") } }.buttonStyle(.plain)
                TextField("你的名字", text: $profile.name)
            }
            Section { Button("保存") { Task { if await model.saveProfile(profile) { dismiss() } } } }
        }.formStyle(.grouped).navigationTitle("个人资料")
        .sheet(isPresented: $avatar) { AvatarEditor(image: $profile.avatar, name: profile.name.isEmpty ? "我" : profile.name) }
    }
}
