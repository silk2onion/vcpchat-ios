import Foundation
public enum AppTheme: String, Codable, CaseIterable, Sendable { case ink, paper, aurora
    public var title: String { switch self { case .ink: "墨色"; case .paper: "纸色"; case .aurora: "极光" } }
}
public enum AppWallpaper: String, Codable, CaseIterable, Sendable { case forest, leaves, none, custom
    public var title: String { switch self { case .forest: "林间夜游"; case .leaves: "雨后绿叶"; case .none: "纯色"; case .custom: "自定义" } }
}
public enum ToolPresentationMode: String, Codable, CaseIterable, Sendable {
    case legacy, compact, grouped, inline, process
    public var title: String {
        switch self {
        case .legacy: "原有卡片"
        case .compact: "紧凑单行"
        case .grouped: "分组折叠"
        case .inline: "单行合并"
        case .process: "整轮折叠"
        }
    }
}
public enum ToolDefaultExpansion: String, Codable, CaseIterable, Sendable {
    case attention, none, all
    public var title: String {
        switch self {
        case .attention: "失败与待确认"
        case .none: "全部收起"
        case .all: "全部展开"
        }
    }
}
public struct ToolDisplay: Codable, Sendable, Equatable {
    public var mode: ToolPresentationMode
    public var expansion: ToolDefaultExpansion
    public init(mode: ToolPresentationMode = .legacy, expansion: ToolDefaultExpansion = .attention) {
        self.mode = mode; self.expansion = expansion
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decodeIfPresent(ToolPresentationMode.self, forKey: .mode) ?? .legacy,
                  expansion: try values.decodeIfPresent(ToolDefaultExpansion.self, forKey: .expansion) ?? .attention)
    }
}
public struct AppearanceSettings: Codable, Sendable, Equatable {
    public var theme = AppTheme.ink
    public var wallpaper = AppWallpaper.forest
    public var wallpaperCustom = ""
    /// Percentage, matching the desktop/mobile settings contract.
    public var wallpaperDim = 58.0
    public var wallpaperBlur = 0.0
    public var tools = ToolDisplay()
    public init() {}
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decode(AppTheme.self, forKey: .theme)
        wallpaper = try values.decode(AppWallpaper.self, forKey: .wallpaper)
        wallpaperCustom = try values.decode(String.self, forKey: .wallpaperCustom)
        wallpaperDim = try values.decode(Double.self, forKey: .wallpaperDim)
        wallpaperBlur = try values.decode(Double.self, forKey: .wallpaperBlur)
        tools = try values.decodeIfPresent(ToolDisplay.self, forKey: .tools) ?? ToolDisplay()
    }
}
