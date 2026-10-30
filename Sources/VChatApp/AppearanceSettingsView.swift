import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VChatCore
import VChatRendering

struct AppearanceSettingsView: View {
    @Bindable var model: ChatViewModel
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        let photoTitle = loading ? "正在读取…" : "选择照片"
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("主题") { Picker("主题", selection: $model.appearance.theme) { ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented) }
            Section("壁纸") {
                ForEach([AppWallpaper.forest, .leaves, .none], id: \.self) { wallpaper in choice(wallpaper) }
                if !model.appearance.wallpaperCustom.isEmpty { choice(.custom) }
            }
            Section("自己的照片") {
                PhotosPicker(selection: $photo, matching: .images) { Label(photoTitle, systemImage: "photo") }.disabled(loading)
                Button("从文件选择", systemImage: "folder") { importing = true }.disabled(loading)
            }
            if model.appearance.wallpaper != .none {
                Section("调整背景") {
                    LabeledContent("背景遮罩", value: "\(Int(model.appearance.wallpaperDim))%")
                    Slider(value: $model.appearance.wallpaperDim, in: 15...90, step: 1, onEditingChanged: persistSlider)
                    LabeledContent("背景模糊", value: "\(Int(model.appearance.wallpaperBlur)) px")
                    Slider(value: $model.appearance.wallpaperBlur, in: 0...16, step: 1, onEditingChanged: persistSlider)
                    Button("恢复推荐效果", systemImage: "arrow.counterclockwise") { model.appearance.wallpaperDim = 58; model.appearance.wallpaperBlur = 0; Task { await model.saveAppearance() } }
                }
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .background(ThemeWallpaper(model.appearance, animations: model.renderOptions.motion).ignoresSafeArea())
        .navigationTitle("外观")
        .onChange(of: Choice(theme: model.appearance.theme, wallpaper: model.appearance.wallpaper, custom: model.appearance.wallpaperCustom)) { _, _ in Task { await model.saveAppearance() } }
        .onDisappear { Task { await model.saveAppearance() } }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            loading = true
            Task {
                defer { loading = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ClientError.server("无法读取这张照片") }
                    model.appearance.wallpaperCustom = try await EmbeddedImages.shared.prepareWallpaper(data)
                    model.appearance.wallpaper = .custom; error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            loading = true
            Task {
                defer { loading = false }
                do {
                    model.appearance.wallpaperCustom = try await EmbeddedImages.shared.importWallpaper(url)
                    model.appearance.wallpaper = .custom; error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private struct Choice: Equatable { var theme: AppTheme; var wallpaper: AppWallpaper; var custom: String }
    private func persistSlider(_ editing: Bool) { if !editing { Task { await model.saveAppearance() } } }
    private func choice(_ wallpaper: AppWallpaper) -> some View {
        var preview = model.appearance; preview.wallpaper = wallpaper
        return Button { model.appearance.wallpaper = wallpaper } label: {
            HStack(spacing: 14) {
                ThemeWallpaper(preview, animations: false).frame(width: 56, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(wallpaper.title).foregroundStyle(.primary); Spacer()
                if model.appearance.wallpaper == wallpaper { Image(systemName: "checkmark.circle.fill").foregroundStyle(model.appearance.theme.tint) }
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
