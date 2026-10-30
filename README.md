# VChat for iOS

连接自有 VCP 服务的原生聊天客户端。采用 SwiftUI + Swift 6，支持 iOS 17 及更新版本。

> 当前为原生重构预览版：已接通聊天、实时日志和本机记录。富消息、同步、文件管理和语音功能仍在迁移中。

## 开始使用

打开右上角的 **连接设置**，填写：

| 项目 | 填写内容 |
| --- | --- |
| 服务器 | 手机可访问的 VCP 地址，建议使用 HTTPS |
| 聊天 API Key | VCP 聊天服务密钥 |
| 模型 ID | 直接填写，或点“鉴权并读取模型”后搜索选择 |
| VCPLog Key | 实时日志的独立密钥；与聊天密钥分开填写 |

保存后即可发送消息。需要实时日志时，在连接设置里点 **连接 WebSocket**，再打开右上角的波形图标。

已有桌面 VCPChat 连接可以通过 **导入桌面 VCPChat 连接…** 选择原版 `AppData/settings.json`。
只读取连接信息，不改原文件或旧会话；密钥保存在系统钥匙串。

模型列表支持搜索、最近使用和本机缓存。每次只展示一小批，点“再显示 40 个”继续浏览，数百个 ID 不会一次性铺满页面。

“OpenAI 兼容”使用 `/v1/chat/completions`；“VCP 工具模式”使用 `/v1/chatvcp/completions`，都通过 SSE 流式接收。WebSocket 用于 VCPLog 推送。

Temperature 默认不发送，只有打开“发送 Temperature”才会启用。Agent 可设置独立数值，否则继承全局数值。

## Agent 通讯录

在“通讯录”点 ＋ 创建 Agent，设置名字、简介、系统提示词和模型。模型留空时使用全局模型。
点 Agent 进入它的独立对话；右侧菜单可编辑资料或将其设为主 Agent。主 Agent 固定在“会话”顶部。
删除 Agent 不会删除历史消息。点 Agent 头像可从照片或文件选择图片，调整裁剪、缩放与位置。

在“我 → 个人资料”设置你的名字与头像；资料保存在本机。

## 群聊

在“通讯录 → 创建群聊”选择成员、设置群提示词，并选择发言方式：@点名否则轮流、轮流一位、随机、仅点名、每位依次回复。
成员会保留各自身份和系统提示词，按顺序读取前面成员的回复。可为群聊指定统一模型；留空时使用各成员模型。
群聊支持独立话题、头像和发言顺序调整，停止生成会同时停止本轮后续成员。

## 聊天与本机记录

- 回复使用原生文字流式显示，可停止生成，已收到的内容会保留。
- 输入框支持多行输入，点箭头发送。
- 工具请求、执行结果、思考链、日记与工具摘要显示为原生卡片；流式未完成的卡片会保持展开。代码块中的协议示例不会被误识别。
- 聊天记录保存在本机，重启后可以继续查看。
- 点放大镜搜索本机消息，至少输入 3 个字符，支持中英文。
- 中断或失败的消息不会自动重复发送。

每位 Agent 有独立对话，可从聊天顶部的历史按钮新建、切换、重命名和删除话题。每个话题分别保留草稿；切到其他话题时，正在生成的回复会继续接收。普通文字直接由原生 Text 显示；Markdown 标题、引用、列表和表格使用原生视图，代码支持语法高亮和复制，行内与独立公式使用原生数学排版。富内容在独立 Actor 中解析，可视区外停止解析。HTML 暂按文字显示；后台续流和系统推送尚未开放。

## 安装

目前通过源码运行：使用完整版 **Xcode 16 或更新版本** 打开 `VChat.xcodeproj`，选择 **VChat** 和 iPhone 模拟器后运行。
安装到自己的 iPhone 时，在签名设置中选择开发团队，并启用手机的开发者模式。

同一套原生代码也支持 macOS 14+。使用 Swift 6 构建根目录的 Swift Package 可运行 Mac 客户端。

## 数据与隐私

连接密钥保存在系统钥匙串。聊天记录使用独立的本机数据库，不会覆盖旧客户端的数据；当前版本不会自动导入或同步旧会话。
发送消息时，会把当前会话内容发送给你配置的 VCP 服务。请使用可信服务器。

## 许可与致谢

本项目以 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) 发布，完整条款见 `LICENSE`。
Copyright 2026 VCPChat iOS contributors。

本客户端参考并适配了 [VCPMobile](https://github.com/MRiecy/VCPMobile)（MRiecy / Nova）、[VCPChat](https://github.com/lioensky/VCPChat) 与 [VCPToolBox](https://github.com/lioensky/VCPToolBox)（lioensky）的协议与交互。
原 Tauri/Vue 实现已重写为 SwiftUI 原生客户端，应用图标沿用原 iOS 客户端；相关历史来源与改动保留在 Git 历史中。

数据库组件 [GRDB.swift](https://github.com/groue/GRDB.swift) 使用其独立的 [MIT 许可](https://github.com/groue/GRDB.swift/blob/v7.0.0/LICENSE)。

Markdown 解析采用 [swift-markdown](https://github.com/swiftlang/swift-markdown)（Apache 2.0 + Runtime Library Exception），代码高亮采用 [HighlighterSwift](https://github.com/smittytone/HighlighterSwift)（MIT），原生公式采用 [SwiftMath](https://github.com/mgriebling/SwiftMath)（MIT）。各组件及附带字体保留各自许可。
