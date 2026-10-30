# VChat Native · Phase 1

连接自有 VCP 后端的 **SwiftUI + Swift 6 原生客户端**，最低 iOS 17。
App 入口是 `VChatApp`；聊天列表、消息和输入框均为原生控件。Tauri、Vue 和 Rust 已从当前应用构建中移除。

## 开始聊天

1. 打开右上角“连接设置”，填写服务器、聊天 API Key 和模型 ID。
2. 点“鉴权并读取模型”，可搜索模型，或直接填写模型 ID。
3. 如需 VCPLog，另填 WebSocket Key，再点“连接 WebSocket”。
4. 保存后发送消息，回复流式显示。停止或断流后，已收到的内容保留在本机。

Mac 上也可点“导入桌面 VCPChat 连接…”，在系统文件选择器里选择原版 `AppData/settings.json`。
仅导入 `vcpServerUrl`、`vcpApiKey`、`vcpLogKey`；不改动原文件、旧会话或旧 App 数据。
密钥存入本机钥匙串，不写入源码、UserDefaults 或聊天数据库。连接服务器应使用 HTTPS。

**现有后端协议**：聊天使用 `POST /v1/chat/completions` 的 Bearer 鉴权与 SSE；推送使用 `/VCPlog/VCP_Key=…` 的 WebSocket，收到 `connection_ack` 后才显示“已连接”。两条通道独立。

## 在 Xcode 运行 iOS App

使用完整版 Xcode 16 或更新版本，安装 iOS 平台与模拟器。打开 **`VChat.xcodeproj`**，选择 **VChat** scheme 和 iPhone 模拟器后运行。
真机运行时，在 Signing & Capabilities 中选择自己的开发团队；本阶段不提供签名 IPA。

项目和 Swift Package 都启用 **Swift 6 + Complete Concurrency Checking**，GRDB 固定为 7.0.0。

```bash
xcodebuild -project VChat.xcodeproj -scheme VChat \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$HOME/CodexArtifacts/vchat-native/DerivedData" \
  CODE_SIGNING_ALLOWED=NO build
```

修改 App 源文件清单后运行 `python3 scripts/generate-xcode-project.py`，更新已签入的工程；普通 Swift 文件内容修改无需重生成。

## 在 Mac 验证同一套原生代码

```bash
export VCHAT_ARTIFACTS="$HOME/CodexArtifacts/vchat-native-local"
bash scripts/run-mac.sh
open "$VCHAT_ARTIFACTS/products/VChat Native.app"
```

Mac 需要 macOS 14+、Swift 6。Mac 验证共享 UI、Actor、网络和数据库；iOS 的编译、键盘和生命周期仍由 iOS 目标单独验收。

## 测试

```bash
export VCHAT_ARTIFACTS="$HOME/CodexArtifacts/vchat-native-tests"
bash scripts/test-native.sh
```

Swift Testing 覆盖 UTF-8/SSE 边界、16/8 ms 缓冲、鉴权、真实 URLSession 流、停止/断流保留、慢消费者、WebSocket ACK、WAL/FTS5 与恢复。协议夹具只监听本机，使用固定假密钥；Node 仅用于测试，不进入 App。
直接 `swift test` 可运行解析测试；完整网络与存储测试使用上述脚本分配隔离输出目录。

GitHub Actions `Native SwiftUI Phase 1` 执行原生测试、iOS 模拟器构建与启动，保存日志和截图，不上传真实连接配置，也不打 IPA。

## 数据与实现边界

- `SessionActor` 持有网络状态机、解码和文字组装，向主线程交付聚合后的完整快照。16/8 ms 定时预算不是屏幕 VSync 测量；尚未给出真机 120 Hz 帧耗时结论。
- `@Observable` 的消息对象保持稳定身份；当前消息行读取自己的文字。列表使用 `ScrollView + LazyVStack`，不会每个 Token 重建整份消息数组。
- GRDB `DatabasePool` 使用 SQLite WAL。消息先本地落盘，回复定期保存；重启把未完成回复标记为中断。FTS5 trigram 搜索至少输入 3 个字。
- 原生数据库位于 `Application Support/VChatNative/chat.sqlite`，与旧客户端分离。待确认消息保存在 Outbox；后端尚无聊天幂等确认协议，因此不会盲目自动重发。
- **本阶段交付 Level 1 原生文本流式 Demo**。多会话/Agent、Level 2 代码与公式、Level 3 微型 WebView 池、增量同步、文件管理、TTS、APNs 和后台续流尚未移植。旧实现可从 Git 历史恢复；旧功能不应被当作本阶段已完成。

## 结构

```text
VChat.xcodeproj/           iOS 原生入口和共享 scheme
Sources/VChatApp/          SwiftUI 界面、@Observable 状态
Sources/VChatCore/         SessionActor、SSE、GRDB、钥匙串
Tests/VChatCoreTests/      解析、协议和数据库测试
Configuration/            iOS plist、图标
scripts/                  Mac 验证、测试夹具、工程生成
```

协议参考和后续迁移记录见 `docs/NATIVE_PHASE1.md`。旧同步协议调查保存在 `docs/UPSTREAM_SYNC_AND_FILES.md`，其中的旧 UI 路径不适用于本阶段原生 Demo。
