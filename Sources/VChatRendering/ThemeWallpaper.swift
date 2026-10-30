import SwiftUI
import VChatCore
import ImageIO

extension AppTheme {
    public var background: Color { switch self { case .ink: Color(red: 16/255, green: 18/255, blue: 20/255); case .paper: Color(red: 246/255, green: 247/255, blue: 248/255); case .aurora: Color(red: 16/255, green: 27/255, blue: 33/255) } }
    public var tint: Color { switch self { case .paper: Color(red: 39/255, green: 135/255, blue: 82/255); case .aurora: Color(red: 141/255, green: 214/255, blue: 228/255); case .ink: Color(red: 136/255, green: 214/255, blue: 176/255) } }
}
public struct ThemeWallpaper: View {
    public var settings: AppearanceSettings
    public var animations: Bool
    @State private var image: CGImage?
    public init(_ settings: AppearanceSettings, animations: Bool = true) { self.settings = settings; self.animations = animations }
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                settings.theme.background
                switch settings.wallpaper {
                case .forest, .leaves: if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                case .custom: NativeRaster(settings.wallpaperCustom, animations: animations)
                case .none: Color.clear
                }
            }.frame(width: geometry.size.width + 36, height: geometry.size.height + 36).offset(x: -18, y: -18).blur(radius: min(16, max(0, settings.wallpaperBlur)))
            if settings.wallpaper != .none { (settings.theme == .paper ? Color(red: 242/255, green: 248/255, blue: 243/255) : settings.theme.background).opacity(min(90, max(15, settings.wallpaperDim)) / 100) }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
        .task(id: settings.wallpaper) {
            let value = await BundledWallpapers.shared.image(settings.wallpaper)
            if !Task.isCancelled { image = value }
        }
    }
}

private actor BundledWallpapers {
    static let shared = BundledWallpapers()
    private var images: [AppWallpaper: CGImage] = [:]
    func image(_ wallpaper: AppWallpaper) -> CGImage? {
        guard wallpaper == .forest || wallpaper == .leaves else { return nil }
        if let image = images[wallpaper] { return image }
        let name = wallpaper == .forest ? "forest-night" : "leaves"
        guard let url = Bundle.module.url(forResource: name, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        images[wallpaper] = image
        return image
    }
}
