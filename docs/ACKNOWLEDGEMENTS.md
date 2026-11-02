# 开源致谢

## VCP 生态

VChat 参考并适配了以下项目的协议与交互：

- [VCPMobile](https://github.com/MRiecy/VCPMobile)：MRiecy / Nova。
- [VCPChat](https://github.com/lioensky/VCPChat) 与 [VCPToolBox](https://github.com/lioensky/VCPToolBox)：lioensky。

林间夜游与雨后绿叶壁纸沿用原 iOS 客户端素材。

## 第三方组件

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 本机数据库 | [MIT](https://github.com/groue/GRDB.swift/blob/v7.0.0/LICENSE) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown 解析 | Apache 2.0 + Runtime Library Exception |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) | 代码高亮 | MIT |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 公式排版 | MIT |
| [SDWebImage](https://github.com/SDWebImage/SDWebImage) | 动态图片 | MIT |
| [MermaidKit](https://github.com/2389-research/MermaidKit) | 原生图表 | [MIT](../Vendor/MermaidKit/LICENSE) |

各组件及附带字体保留各自许可。

### MermaidKit 归属与适配

MermaidKit 2.10.2，源码版本 `8556a1b8`。Copyright 2026 Clint Ecker。

本项目纳入 Apple 原生解析、布局和绘制组件，适配 Swift 6.0 工程配置，添加有像素上限的 Actor 绘制入口，并修正显式 XY 轴范围与裁切。完整许可保留于组件目录及应用资源。
