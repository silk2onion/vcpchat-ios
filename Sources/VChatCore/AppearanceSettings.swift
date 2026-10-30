import Foundation
public enum AppTheme: String, Codable, CaseIterable, Sendable { case ink, paper, aurora
    public var title: String { switch self { case .ink: "墨色"; case .paper: "纸色"; case .aurora: "极光" } }
}
public enum AppWallpaper: String, Codable, CaseIterable, Sendable { case forest, leaves, none, custom
    public var title: String { switch self { case .forest: "林间夜游"; case .leaves: "雨后绿叶"; case .none: "纯色"; case .custom: "自定义" } }
}
public struct AppearanceSettings: Codable, Sendable, Equatable {
    public var theme = AppTheme.ink
    public var wallpaper = AppWallpaper.forest
    public var wallpaperCustom = ""
    /// Percentage, matching the desktop/mobile settings contract.
    public var wallpaperDim = 58.0
    public var wallpaperBlur = 0.0
    public init() {}
}
