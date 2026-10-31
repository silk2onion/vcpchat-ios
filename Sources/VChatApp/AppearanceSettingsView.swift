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
        let palette = self.palette
        let photoTitle = loading ? "正在读取…" : "选择照片"
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                if let error { Text(error).foregroundStyle(.red) }
                feature("主题","让文字、面板和壁纸彼此衬托。",icon: "palette")
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases,id: \.self) { theme in
                        Button { model.appearance.theme = theme } label: {
                            VStack(alignment: .leading,spacing: 10) {
                                themePreview(theme).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
                                HStack { Text(theme.title).font(.system(size: 14,weight: .semibold)); Spacer(minLength: 0); if model.appearance.theme == theme { WorkspaceGlyph("check",size: 16).foregroundStyle(palette.accent) } }
                            }.padding(10).workspaceGlass(palette,radius: 14).overlay(RoundedRectangle(cornerRadius: 14).stroke(model.appearance.theme == theme ? palette.accent : .clear,lineWidth: 1.5))
                        }.accessibilityAddTraits(model.appearance.theme == theme ? [.isSelected] : [])
                    }
                }
                feature("壁纸","也可以使用自己的照片。",icon: "image")
                LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) {
                    choice(.forest); choice(.leaves); choice(.none)
                    if !model.appearance.wallpaperCustom.isEmpty { choice(.custom) }
                    PhotosPicker(selection: $photo,matching: .images) { Label(photoTitle,systemImage: "square.and.arrow.up").font(.system(size: 15,weight: .semibold)) }.frame(maxWidth: .infinity).frame(height: 150).foregroundStyle(palette.accent).workspaceGlass(palette,radius: 18).disabled(loading)
                }
                Button("从文件选择",systemImage: "folder") { importing = true }.foregroundStyle(palette.accent).disabled(loading)
                if model.appearance.wallpaper != .none {
                    VStack(spacing: 24) {
                        VStack(spacing: 12) { LabeledContent("背景遮罩",value: "\(Int(model.appearance.wallpaperDim))%"); Slider(value: $model.appearance.wallpaperDim,in: 15...90,step: 1,onEditingChanged: persistSlider) }
                        VStack(spacing: 12) { LabeledContent("背景模糊",value: "\(Int(model.appearance.wallpaperBlur)) px"); Slider(value: $model.appearance.wallpaperBlur,in: 0...16,step: 1,onEditingChanged: persistSlider) }
                        Button("恢复推荐效果",systemImage: "arrow.counterclockwise") { model.appearance.wallpaperDim = 58; model.appearance.wallpaperBlur = 0; Task { await model.saveAppearance() } }.foregroundStyle(palette.accent)
                    }.font(.system(size: 14)).padding(20).workspaceGlass(palette)
                }
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }.buttonStyle(WorkspacePress()).tint(palette.accent).foregroundStyle(palette.ink)
        .background(ThemeWallpaper(model.appearance,animations: model.renderOptions.motion).ignoresSafeArea()).navigationTitle("外观")
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
    private var palette: WorkspacePalette { .init(theme: model.appearance.theme) }
    private func feature(_ title: String,_ subtitle: String,icon: String) -> some View { HStack(spacing: 12) { WorkspaceGlyph(icon).foregroundStyle(palette.accent); VStack(alignment: .leading,spacing: 4) { Text(title).font(.system(size: 19,weight: .semibold)); Text(subtitle).font(.system(size: 13)).foregroundStyle(palette.muted) } } }
    private func themePreview(_ theme: AppTheme) -> some View { VStack(alignment: .leading,spacing: 12) { Capsule().fill(theme == .paper ? .black.opacity(0.1) : .white.opacity(0.15)).frame(width: 65,height: 13); HStack { Spacer(); Capsule().fill(theme.tint.opacity(0.5)).frame(width: 55,height: 14) }; Capsule().fill(theme == .paper ? .black.opacity(0.1) : .white.opacity(0.15)).frame(width: 80,height: 14); Spacer() }.padding(10).background(theme.background) }
    private func choice(_ wallpaper: AppWallpaper) -> some View {
        Button { model.appearance.wallpaper = wallpaper } label: {
            ZStack(alignment: .bottom) {
                if wallpaper == .none { palette.canvas } else { WallpaperThumbnail(wallpaper,custom: model.appearance.wallpaperCustom) }
                HStack { Text(wallpaper.title).font(.system(size: 13,weight: .semibold)); Spacer(minLength: 0); if model.appearance.wallpaper == wallpaper { WorkspaceGlyph("check",size: 17) } }.foregroundStyle(.white).padding(12).padding(.top,12).background(LinearGradient(colors: [.clear,.black.opacity(0.75)],startPoint: .top,endPoint: .bottom))
            }.frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(model.appearance.wallpaper == wallpaper ? palette.accent : palette.line,lineWidth: model.appearance.wallpaper == wallpaper ? 2 : 0.6))
        }.accessibilityLabel(wallpaper.title).accessibilityAddTraits(model.appearance.wallpaper == wallpaper ? [.isSelected] : [])
    }
}
