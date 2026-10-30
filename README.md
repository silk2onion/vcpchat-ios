# VChat for iOS

连接自有 VCP 服务的原生聊天客户端。采用 SwiftUI + Swift 6，支持 iOS 17 及更新版本。

> 当前为原生重构预览版：已接通聊天、实时日志和本机记录。群聊、富消息、同步、文件管理和语音功能仍在迁移中。

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

服务器使用 `/v1/chat/completions` 的 SSE 聊天协议；WebSocket 用于 VCPLog 推送。当前不支持需要额外协议转换的聊天接口。

## Agent 通讯录

在“通讯录”点 ＋ 创建 Agent，设置名字、简介、系统提示词和模型。模型留空时使用全局模型。
点 Agent 进入它的独立对话；右侧菜单可编辑资料或将其设为主 Agent。主 Agent 固定在“会话”顶部。
删除 Agent 不会删除历史消息。

## 聊天与本机记录

- 回复使用原生文字流式显示，可停止生成，已收到的内容会保留。
- 输入框支持多行输入，点箭头发送。
- 聊天记录保存在本机，重启后可以继续查看。
- 点放大镜搜索本机消息，至少输入 3 个字符，支持中英文。
- 中断或失败的消息不会自动重复发送。

每位 Agent 有独立对话。代码、公式和 HTML 暂按文字显示；后台续流和系统推送尚未开放。

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
