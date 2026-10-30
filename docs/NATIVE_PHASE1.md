# Native Phase 1：运行链路与验收

## 这次迁移交付什么

```text
VChatApp (@main, SwiftUI)
└─ ChatView / ChatViewModel (@MainActor, @Observable)
   ├─ SessionActor
   │  ├─ URLSession.AsyncBytes → SSEByteDecoder → token assembly
   │  ├─ 16/8 ms timer → bounded full snapshots → AsyncThrowingStream
   │  └─ URLSessionWebSocketTask → connection_ack / VCPLog events
   ├─ ChatStore actor → GRDB DatabasePool → WAL + FTS5
   └─ CredentialVault actor → system Keychain
```

Swift 6 complete 检查覆盖全部自有 Swift 目标，没有 `@unchecked Sendable`、`@preconcurrency` 或 Swift 5 降级。主线程只处理可观察界面状态；SSE/WS 解码、文字组装与数据库查询在对应 Actor/数据库队列中完成。

每次传输携带完整累计快照，`bufferingNewest(1)` 在界面较慢时可以跳过中间快照，不丢正文。Pacer 按单调时钟 16/8 ms 预算交付脏数据，结束、停止和异常立即交付尾部。当前为时钟节流；真机 VSync、120 Hz 帧耗时和能耗尚未测量。

## 按原库实际协议连接

本次读取的 VCPToolBox 源码版本为 `0c919a3`：

- `server.js`：聊天 `POST /v1/chat/completions`，Bearer API Key，`stream: true`；`GET /v1/models` 同样鉴权。
- `WebSocketServer.js`：`/VCPlog/VCP_Key=<key>`，鉴权成功发 `connection_ack`。这是 VCPLog/VCPInfo 推送，不是聊天 Token 通道。

服务端保持不变。两条连接分别鉴权；聊天 API Key 不用于推送，VCPLog Key 不放进聊天请求。WebSocket 使用原库的路径密钥协议，客户端不记录带密钥的连接 URL。

## 数据怎么保留

原生数据库：`Application Support/VChatNative/chat.sqlite`。旧客户端的数据目录没有写入或迁移。
用户消息先事务性写入聊天表和 Outbox，再发网络请求；已接受的请求移出 Outbox。回复每 500 ms 或终态落盘，崩溃后可能丢失最后一个保存间隔内的尾部。重启将遗留 connecting/streaming 记录标为 interrupted。

Outbox 是本机待确认记录；尚未接服务器增量游标、聊天幂等确认和重放协议，当前不会自动重发。FTS5 使用 trigram，支持至少 3 个字符的中英文子串搜索，输入作为字面量参数，不执行 FTS 表达式。

已有桌面连接通过系统文件选择器只读导入，仅解析 `vcpServerUrl`、`vcpApiKey`、`vcpLogKey`；忽略其他设置、文件服务密码和聊天记录。原生设置使用独立 UserDefaults 与钥匙串服务 `app.vcpchat.native`。

## Mac 实测（2026-10-30）

- macOS 15.2 arm64，Apple Swift 6.0.3。
- 原生 SwiftUI App 编译并启动；App 中导入原桌面连接，密钥保持遮蔽。
- `https://agent.sijinworld.com` 聊天鉴权成功，读取 **380** 个模型。
- 模型 `gemini-3.8-flash-high`：实际发送原生连通性提示，收到 12 行回复，最终标记 `STREAM-END-20261030` 完整显示，状态“回复完成”。模型回复中的性能描述是模型生成内容，不作为性能测量。
- 退出后重新启动最终 Mac 构建，测试消息和结束标记从本机数据库恢复；中文“原生测试”搜索能找到该回复与提示。
- 同时打开 VCPLog，WebSocket 状态“已连接”，流式诊断：13 个原始事件、14 次界面快照（包含连接/结束状态），解析与组装位于独立 Actor。
- 16 项协议/存储/解析测试通过。高频夹具 502 个 SSE 事件 → 4 次界面快照；慢消费者仍收到完整尾部；HTTP 401、异常断流、停止后新流、WS 错密钥与 ACK 顺序均通过。
- 小型数据库夹具中 20 次 FTS5 查询合计 3.64 ms。这是当前 Mac/小样本结果，不是 iPhone 或大规模数据库的性能结论。

### 发现并修正的问题

1. **SSE 空行丢失**：Apple 的 `AsyncBytes.lines` 会跳过事件分隔空行。改用 Actor 内字节分帧，支持 LF/CR/CRLF、跨包 UTF-8、BOM 和尾部刷新；增加相应回归测试。
2. **Swift Observation 限制**：`@Observable`/`@State` 的属性声明必须各自独立，已拆开多变量声明，保持 Swift 6 严格检查。
3. **本机 CLT 混装**：系统 ManifestAPI 的私有 swiftinterface 是旧 5.10，而公开接口为 6.0.3。仅在集中归档的临时目录复制 ManifestAPI 并移除过期私有接口，通过 SwiftPM 官方 `SWIFTPM_CUSTOM_LIBS_DIR` 指向该副本。系统 CLT 未改动，工程语言版本未降级；正常 Xcode 不需要此临时修复。
4. **本机没有完整版 Xcode/iOS SDK**：本机 `xcodebuild -version` 失败，原文为：

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

Mac 成功不替代 iOS 验收。原生 Actions 流程独立执行 iOS 模拟器构建、安装、启动和截图，结果以该次运行日志为准。

## 下一阶段保留的边界

本次按 Phase 1 交付最小原生通路。Level 2 原生 Markdown/代码/公式、仅匹配 `<div id="vcp-root">` 的 Level 3 微 WebView 池、Agent/多会话、同步/文件授权/TTS、APNs 与后台任务恢复尚未实现；当前消息仅作原生纯文本显示。全屏 WebKit、Tauri 前端和 Rust 主入口均已移除。

历史版本完整保存在 Git 基线 `64bcd14`。本地完整回滚材料及原版源文件位于集中归档目录 `vcpchat-native-phase1-20261030T175226Z/backups`，无须覆盖或卸载旧 App。
