# VCPChat iOS

连接你自己的 [VCPToolBox](https://github.com/lioensky/VCPToolBox) 的手机聊天客户端。服务器地址和密钥在设置里填写，只保存在这台设备上，仓库和构建产物里没有任何密钥。

界面可以在 Linux 上用浏览器直接用。iOS 安装包要在 macOS 上签名后再用 AltStore 或 Sideloadly 装到手机。

## 技术选择

[VCPMobile](https://github.com/MRiecy/VCPMobile) 是 Tauri 2、Vue 3 和 Rust。Tauri 2 能打 iOS，所以这里沿用同一套分层，而不是改写成 SwiftUI：

- Vue 3 负责手机界面：对话、群组、笔记、日志、主题。
- TypeScript 负责协议：OpenAI 兼容的 SSE、工具标记、日记管理接口、WebSocket 地址。这些在 Linux 上有单元测试。
- Rust 只在 Tauri（也就是 iOS 和桌面壳）里发 HTTP 和 WebSocket。WKWebView 直接 `fetch` 你的服务器时会被跨域策略拦住，原生请求没有这个问题。浏览器预览仍走页面里的 `fetch`，方便在没有 Xcode 的机器上检查界面。

对照过的上游版本写在 [NOTICE.md](NOTICE.md)。两个上游仓库都是 CC BY-NC-SA 4.0，本仓库同样以此许可发布。

## 功能对照

桌面端取自 `lioensky/VCPChat` 在 `942ad42`（2026-10-29）附近的能力，移动端取自 `MRiecy/VCPMobile` 在 `a8482b6`（2026-10-16）的能力。近期桌面提交里，和手机有关的是流式推理字段、工具标记、群组点名、笔记和日志这几块；音乐、语音唤醒、Loom、VGame 留在桌面。

| 能力 | 桌面 VCPChat | VCPMobile | 本 iOS 应用 |
| --- | --- | --- | --- |
| 自有服务器 URL 与 API Key | 有 | 有 | 有，只存在本机 IndexedDB |
| OpenAI 兼容流式对话 | 有 | 有，由 Rust 读 SSE | 有。浏览器里直接读 SSE；iOS 壳里流由 Rust 持有并按序号记下每一段，解析仍在同一套 TypeScript |
| 流式保活与续写 | 有，后台流可切换话题继续 | 有，Android 前台服务保活 | 有。切话题、切到别的 app 再回来，流都不断；WebView 漏掉的事件或被系统重载后，从 Rust 记下的分段补齐或重新接上。进后台时立即保存已写部分。被系统断开时保留已写内容、标成「已中断」，点「继续写」让同一位助手接着写进同一个气泡。应用被杀后重开，没写完的回复同样标成已中断 |
| `/v1/chatvcp/completions` 工具路由 | 有 | 有 | 有，设置里切换 |
| 模型列表 `/v1/models` | 有 | 有 | 有 |
| 本地话题与消息 | 有 | 有，SQLite | 有，IndexedDB |
| 助手与系统提示 | 有 | 有，并可与桌面同步 | 有，仅本机 |
| 群组 | 有，发言策略、邀请、审批看门狗 | 有 | 有。`@名字`、轮流一位、或每位依次回复 |
| 工具调用渲染 | 有，完整扫描器和审批卡 | 有 | 有。`TOOL_REQUEST`、调用结果汇总（拆出工具名、执行状态、返回内容）、`<think>`、VCP 元思考链、本轮工具调用摘要、角色分界。代码围栏里的标记不当成工具 |
| 日记气泡 | 有，`DailyNote` create / update 和旧版 `DailyNoteStart` | 有日记块 | 有。create 渲染成日记卡片，update 渲染成「原文 → 改为」，流式中也能看到半截 |
| 代码高亮与复制 | 有，highlight.js | HTML 预览块里有 | 有。highlight.js 按需加载，每个代码块带复制按钮 |
| 数学公式 | 有，KaTeX | 有，KaTeX | 有。KaTeX 按需加载，支持 `$…$`、`$$…$$`、`\(…\)`、`\[…\]`，价格这类 `$5` 不会被误认 |
| HTML 气泡 | 有，回复里的 HTML 直接渲染，代码块可「播放」 | 有 HTML 预览块 | 有。整页 HTML 或带 `<style>`/`<script>` 的回复放进 `sandbox="allow-scripts"` 的 iframe，代码块可预览。iframe 拿不到应用的 DOM、存储和 Tauri 接口，CSP 禁止它发网络请求 |
| 图片与视频预览 | 有 | 有图片查看器 | 有。图片点开全屏，视频链接变成播放器，附件图显示缩略图 |
| 气泡动画 | 有，回复里的动画脚本在气泡内运行 | 有少量过渡动画 | 有。气泡入场、流式中的呼吸边框、展开动画；系统开了「减弱动态效果」时关闭。HTML 气泡里的 CSS / JS 动画在沙箱里运行 |
| 高级渲染省电开关 | 有「消息渲染」分区：平滑流式输出开关和流式动效预设，没有总开关 | 无 | 有。设置里的「高级渲染」总开关，关掉只渲染轻量 Markdown，不下载高亮、公式、图表库；开着时可以单独关代码高亮、公式、Mermaid、HTML 气泡、图片视频预览和动画。切换后已有消息立刻重渲染 |
| 桌面推送 `DESKTOP_PUSH` | 有 | 无，在规划中 | 只显示成折叠卡片，不在手机上执行 |
| 推理流 `reasoning_content` | 有 | 有思考块 | 有，折叠在「思考」里 |
| 图片与文本附件 | 有 | 有 | 有。图片上限 1.5MB，文本 200KB，最多 4 个。不接受 SVG |
| 主题 | 有，分布式主题和壁纸 | 有 | 有三种本机主题：墨色、纸色、极光 |
| 笔记 / 日记 | 有本地笔记、网络笔记、Memo | 有日记中心 | 有本机笔记，以及 `/admin_api/dailynotes` 的列表、阅读、保存和搜索 |
| VCPLog WebSocket | `/VCPlog/VCP_Key=`，设备名 `VCPChat-Desktop` | 同一路径 | 同一路径，设备名 `VCPChat-iOS`。断线按指数退避重连；回到前台时立刻重连，离开超过 20 秒的连接即使看起来还开着也重建 |
| VCPInfo WebSocket | 有 | `/vcpinfo/VCP_Key=` | 有，只展示文本帧 |
| 流式桌面 / VCPDesktop | 有 | 无 | 无。悬浮桌面不适合手机 |
| 音乐专注、歌词与 ID3 | 近期有 | 无 | 无 |
| 语音唤醒 | 近期有 | 实验性 | 无 |
| Loom / JEV 浏览器 | 近期有 | 无 | 无 |
| VTrade / VGame | 近期有 | 无 | 无 |
| Mermaid | 有 | 有 | 有。Mermaid 按需加载，`strict` 安全级别，跟随深浅主题 |
| 3D、Canvas 协同 | 有 | 无 | 无原生支持。回复自带的 three.js / canvas 页面可以在 HTML 气泡里跑 |
| 论坛、邮件、任务中心、CLI | 有 | 有 | 无 |
| 与桌面双向同步 | 通过同步插件 | 有 | 无 |
| 工具审批回写 | 有 | 部分 | 无。日志里能看到消息，不能在手机上批 |
| 翻译器 | 近期重做了界面 | 无独立模块 | 无 |
| 后台继续运行 | 无 | Android 前台服务 | 部分。流式中向 iOS 申请后台执行时间，通常约 30 秒；更久会被挂起，回来后按「已中断」处理 |

## 本地运行

需要 Node.js 22 和 pnpm 10。

```bash
pnpm install
pnpm check
pnpm dev
```

浏览器打开 [http://127.0.0.1:43123](http://127.0.0.1:43123)。`pnpm check` 会做类型检查、lint、单元测试和网页构建。

想先看流式回复，可以另开一个终端跑假的 VCP 服务，再在设置里填写：

- 服务器 URL：`http://127.0.0.1:43124`
- API Key：任意非空字符串，例如 `local-demo`
- WebSocket URL：`ws://127.0.0.1:43124`
- WebSocket Key：任意不含空格和斜杠的字符串，例如 `local-demo`
- 刷新模型后可选 `vcp-demo`

```bash
pnpm mock-server
```

这个假服务只监听本机，供界面联调，不是 VCPToolBox。

连真服务器时，把 URL 换成你的 VCPToolBox 地址，例如 `http://192.168.1.8:6005`。工具模式会把路径换成 `/v1/chatvcp/completions`。日记功能另外需要管理面板的用户名和密码。

## 在 Mac 上打 iOS 包

这台开发环境没有 Xcode，下面的步骤要在 macOS 上做。仓库里已经有 Tauri iOS 配置、`fastlane/Fastfile`，以及会打出未签名 IPA 和模拟器包的 GitHub Actions。

准备：Xcode 16 或更新、Rust stable、Node.js 22、pnpm 10。

```bash
pnpm install
pnpm tauri ios init --ci --skip-targets-install   # 只在第一次需要
bash scripts/patch-ios-plist.sh                   # 允许访问你局域网里的 http/ws
bash scripts/build-unsigned-ipa.sh                # dist-ios/VCPChat-unsigned.ipa
bash scripts/build-ios-simulator.sh               # 模拟器 .app
```

装了 fastlane 的话，在仓库根目录也可以：

```bash
fastlane ios unsigned
fastlane ios simulator
```

`patch-ios-plist.sh` 会给生成的 Info.plist 加上：

- 允许访问你自己的 HTTP 服务器和本地网络
- 相册说明，供选择图片附件

Bundle ID 是 `app.vcpchat.ios`。免费 Apple ID 若提示标识符冲突，在 Xcode 的 Signing 里改成你自己的，例如 `app.vcpchat.ios.yourname`。

### 签名并装到手机

未签名 IPA 不能直接装。用免费 Apple ID 时，描述文件大约 7 天后过期，需要重签。

**Sideloadly**

1. 用数据线连接 iPhone，并在手机上信任这台电脑。
2. 打开 Sideloadly，把 `dist-ios/VCPChat-unsigned.ipa` 拖进去。
3. 填 Apple ID。Sideloadly 会重新签名并安装。
4. 在 iPhone 的「设置 → 通用 → VPN 与设备管理」里信任该开发者。

**AltStore**

1. 在电脑上按 [AltStore 的说明](https://altstore.io) 装好 AltServer，并登录 Apple ID。
2. 用 AltStore 安装这个 IPA，或在 Xcode 里打开 `src-tauri/gen/apple` 下初始化出来的工程，选择你的 Team 后直接 Run 到手机。
3. 证书过期后用 AltStore 刷新。

**Xcode**

```bash
open src-tauri/gen/apple/*.xcodeproj
```

选中 `VCPChat_iOS`（名字以 `tauri ios init` 生成为准），在 Signing & Capabilities 里选你的 Team，用真机或模拟器运行。模拟器不需要付费账号。

GitHub Actions 的 `iOS` 工作流会在 `macos-15` 上分别跑未签名设备包和模拟器包，并把 IPA 留在构建产物里。那一步同样没有签名证书。

## 这里验证过什么

在 Linux 上可以验证：

- `pnpm check`：`vue-tsc`、ESLint、Vitest、Vite 生产构建
- 单元测试覆盖：公式和代码不被 Markdown 误伤、VCP 标签解析（日记、工具结果、角色分界、元思考链、摘要）、HTML 沙箱文档与 CSP、只有内容需要时才加载 highlight.js / KaTeX / Mermaid、关掉高级渲染后重渲染为轻量 Markdown、切话题不丢流、断开后保存并续写、重启后恢复或重新接上、原生流按序号补齐漏掉的事件、VCPLog 回前台重连
- 浏览器里的设置、主题、本地笔记、流式回复、工具卡片和日志通道（配合 `pnpm mock-server`）。这一轮的渲染和保活改动只用测试、类型检查、lint 和构建验证过，没有在浏览器里点过

需要一台 Mac 才能验证，本次没有做：

- `tauri ios init` 生成的 Xcode 工程能否完整编译
- 未签名 IPA 和模拟器包是否真的由当前 Tauri CLI 打出
- 真机上的 WKWebView、安全区、键盘、相册选择器
- 局域网 `http` / `ws` 是否被系统的本地网络权限拦住
- 真机上切到后台多久会被挂起、`visibilitychange` 是否按预期触发、HTML 沙箱 iframe 里拿不到 Tauri 接口
- 连上真实 VCPToolBox 时的日记接口和工具流
- 用免费 Apple ID 签名后能否安装

Rust 壳在 macOS 或装了 WebKitGTK 4.1 开发包的 Linux 上可以用 `cargo test --lib --manifest-path src-tauri/Cargo.toml` 编译并跑测试：URL 校验、跨网络分片的 UTF-8 拼接、流日志按序号回放、释放与过期、单条流 8MB 上限。申请 iOS 后台执行时间的代码（`src-tauri/src/background.rs`）只对 `aarch64-apple-ios` 做过单独的类型检查，没有在装了 Xcode 的机器上链接过。GitHub 的 Linux 工作流只跑 `pnpm check`，避免把系统图形库放进每次检查。iOS 链接和签名仍然要在 Mac 上确认。
