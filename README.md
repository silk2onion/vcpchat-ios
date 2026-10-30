# VCPChat iOS

连接你自己的 [VCPToolBox](https://github.com/lioensky/VCPToolBox) 的手机聊天客户端。服务器地址和密钥在设置里填写，只保存在这台设备上，仓库和构建产物里没有任何密钥。

界面可以在 Linux 上用浏览器直接用。iOS 安装包要在 macOS 上签名后再用 AltStore 或 Sideloadly 装到手机。

## 从主 Agent 开始

- **会话**顶部固定你的主 Agent。点名字继续它的会话，点右侧菜单更换主 Agent；更换只改变固定入口，不移动或删除历史。
- **Agent**页添加或编辑图片头像、头像文字、名字、简介、模型和系统提示，也可以创建多 Agent 群聊。
- 每位 Agent 可以有多个独立会话。聊天顶部的历史按钮用来切换，消息输入草稿和附件也按会话分别保留。回复生成时切换会话不会取消原来的流。
- **设置 → 个性化 → Enter 发送消息**：开启后 Enter 发送、Shift+Enter 换行；关闭时 Enter 换行。⌘/Ctrl+Enter 在两种模式下都能发送，中文输入法选字不触发发送。默认关闭并保存在本机。
- 设置按服务器、日志、渲染、外观等分成独立页面。聊天头部与输入栏固定，只有消息区滚动；表单输入不再放大整页。图片预览内仍支持独立缩放。
- 流式接收与界面刷新分离：原始内容照常接收、保存，消息列表每个屏幕帧最多更新一次；结束、中断和切换会话时立即显示最新内容。高亮、公式和图表仍在内容完成且接近可视区时按需处理。

0.2 沿用原来的应用标识、IndexedDB 数据库与数据表，已有 Agent、群聊、会话、消息、笔记和密钥继续使用。

## 把常用操作留在聊天里

- 底栏分为**会话、通讯录、我**。通讯录集中管理 Agent 与群组；笔记、通知中心和设置放在“我”里。设置与笔记都有返回入口，原有地址与数据继续使用。

- 聊天右上角的**铃铛**打开通知中心，不用离开当前会话。分为通知、VCPLog、RAG 监视器；新事件和待审批会显示角标。
- **待审批**可以查看工具名、Agent、参数、变更预览，填写说明后允许一次或拒绝。通过 VCPLog 回写；“已发送 · 等待确认”和服务端回执后的“已允许 / 已拒绝”是不同状态。断线时不发送，也不会在重连后自动重发审批。清空诊断日志会保留未完成的审批。
- **RAG 监视器**把检索问题、知识片段、来源、分数、标签和检索方式展开为卡片，也支持元思考阶段、Agent 私聊、记忆回溯与梦境事件。原始 JSON 可以展开查看或复制。单条事件上限 2MB；超过时显示错误，不把截断 JSON 当成正常事件。
- **设置 → 外观**选择墨色、纸色、极光和壁纸。内置林间夜游、雨后绿叶，也可导入 JPG / PNG / WebP / GIF；壁纸上限 8MB，头像上限 5MB。可调整背景遮罩与模糊，恢复推荐效果。自选图片保存在本机，更新不依赖旧版资源地址。
- 页面前进、返回、弹层和通知抽屉都有进入与退出动画；跟随系统的“减弱动态效果”。

### 数百个模型也能快速选择

在**我 → 设置 → 服务器与模型**读取模型列表后，点模型输入框右侧的箭头，用 ID 关键词搜索；例如 `qwen coder` 会同时匹配这两个词，不区分大小写。最近选择的模型排在前面，完整 ID 不变，也可以直接手动填写列表之外的 ID。

候选列表只挂载可见行及少量预加载行，而非一次创建全部选项。模型目录缓存在本机，切页、重开 App 和编辑 Agent 共用同一份，不重复等待服务器；需要更新时点刷新。修改服务器或 API Key 会清掉旧目录，刷新失败时保留当前连接已有的缓存。Agent 可独立选择模型，或留空继承全局模型。

### 语音与朗读

在**设置 → 语音与朗读**填写手机可访问的服务地址，刷新音色后试听。回复下方的扬声器开始朗读；迷你播放器提供进度、暂停、继续与停止。Agent 资料里的声音设置可以覆盖全局音色。

- **SoVITS（VChat 兼容）**：基础地址；`POST /models` 使用 `version: v2ProPlus`；`POST /v1/audio/speech` 使用 `tts-v2ProPlus`。无鉴权的服务可不填 Key。支持语速和日语音色语言参数。
- **MiMo**：基础地址或完整 `/chat/completions` 接口、API Key、模型与音色。接收 SSE 中的 PCM16 音频，按 24kHz 单声道播放。导演提示词用于情绪、语速及自然语言导演音色。

朗读提取正文，不读工具参数、代码块或隐藏思考。长文本分段合成；当前为手动朗读，不在收到回复时自动播放。桌面本地音色克隆文件不随移动端同步。

### 正则：显示与上下文分开

**设置 → 全局正则**支持新建、排序、启停、试替换、导入与导出；Agent 资料里也能配置专属规则。支持 VChat 与 SillyTavern JSON，先运行全局规则，再运行 Agent 规则。

“显示的消息”只改变画面；“发给模型的上下文”只改变发送副本。保存的原始消息不变。可按用户 / Agent 角色和回合深度筛选，0 是最近一轮，-1 表示不限。

## 技术选择

[VCPMobile](https://github.com/MRiecy/VCPMobile) 是 Tauri 2、Vue 3 和 Rust。Tauri 2 能打 iOS，所以这里沿用同一套分层，而不是改写成 SwiftUI：

- Vue 3 负责手机界面：对话、群组、笔记、日志、主题。
- TypeScript 负责协议：OpenAI 兼容的 SSE、工具标记、日记管理接口、WebSocket 地址。这些在 Linux 上有单元测试。
- Rust 只在 Tauri（也就是 iOS 和桌面壳）里发 HTTP 和 WebSocket。WKWebView 直接 `fetch` 你的服务器时会被跨域策略拦住，原生请求没有这个问题。浏览器预览仍走页面里的 `fetch`，方便在没有 Xcode 的机器上检查界面。

对照过的上游版本写在 [NOTICE.md](NOTICE.md)。两个上游仓库都是 CC BY-NC-SA 4.0，本仓库同样以此许可发布。

## 功能对照

桌面端基础取自 `lioensky/VCPChat` 在 `942ad42`（2026-10-29）附近的能力；本轮语音、正则、审批和观察器协议对照本地桌面源码 `40c0d3c`，移动端取自 `MRiecy/VCPMobile` 在 `a8482b6`（2026-10-16）的能力。近期桌面提交里，和手机有关的是流式推理字段、工具标记、群组点名、笔记和日志这几块；音乐、语音唤醒、Loom、VGame 留在桌面。

| 能力 | 桌面 VCPChat | VCPMobile | 本 iOS 应用 |
| --- | --- | --- | --- |
| 自有服务器 URL 与 API Key | 有 | 有 | 有，只存在本机 IndexedDB |
| OpenAI 兼容流式对话 | 有 | 有，由 Rust 读 SSE | 有。浏览器里直接读 SSE；iOS 壳里流由 Rust 持有并按序号记下每一段，解析仍在同一套 TypeScript |
| 流式保活与续写 | 有，后台流可切换话题继续 | 有，Android 前台服务保活 | 有。切话题时原生流持续，短暂切后台时申请 iOS 执行时间；WebView 漏掉的事件或被系统重载后，从 Rust 记下的分段补齐或重新接上。进后台时立即保存已写部分。被系统断开时保留已写内容、标成「已中断」，点「继续写」让同一位助手接着写进同一个气泡。应用被杀后重开，没写完的回复同样标成已中断 |
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
| 主题与壁纸 | 有，分布式主题和壁纸 | 有 | 墨色、纸色、极光；两张内置壁纸、自选壁纸、遮罩和模糊 |
| 图片头像 | 有 | 有 | 可导入图片，内置 VChat 头像，更新后保留本机图片 |
| TTS 朗读 | SoVITS / MiMo 等 | 有 | SoVITS v2ProPlus、MiMo PCM/SSE；手动朗读与 Agent 音色覆盖 |
| 正则 | VChat / ST 导入，显示与上下文 | 有 | 全局及 Agent 规则，角色、深度、顺序、导入导出、试替换 |
| 笔记 / 日记 | 有本地笔记、网络笔记、Memo | 有日记中心 | 有本机笔记，以及 `/admin_api/dailynotes` 的列表、阅读、保存和搜索 |
| VCPLog WebSocket | `/VCPlog/VCP_Key=`，设备名 `VCPChat-Desktop` | 同一路径 | 同一路径，设备名 `VCPChat-iOS`。断线按指数退避重连；回到前台时立刻重连，离开超过 20 秒的连接即使看起来还开着也重建 |
| VCPInfo WebSocket | 有 | `/vcpinfo/VCP_Key=` | 有，结构化渲染 RAG、思考链、Agent、记忆和梦境；保留完整原始事件 |
| 流式桌面 / VCPDesktop | 有 | 无 | 无。悬浮桌面不适合手机 |
| 音乐专注、歌词与 ID3 | 近期有 | 无 | 无 |
| 语音唤醒 | 近期有 | 实验性 | 无 |
| Loom / JEV 浏览器 | 近期有 | 无 | 无 |
| VTrade / VGame | 近期有 | 无 | 无 |
| Mermaid | 有 | 有 | 有。Mermaid 按需加载，`strict` 安全级别，跟随深浅主题 |
| 3D、Canvas 协同 | 有 | 无 | 无原生支持。回复自带的 three.js / canvas 页面可以在 HTML 气泡里跑 |
| 论坛、邮件、任务中心、CLI | 有 | 有 | 无 |
| 与桌面双向同步 | 通过同步插件 | 有 | 无 |
| 工具审批回写 | 有 | 部分 | 通知中心查看参数、一次性允许或拒绝、填写原因；通过 VCPLog 原生 WebSocket 回写并等待服务端回执 |
| 翻译器 | 近期重做了界面 | 无独立模块 | 无 |
| 后台继续运行 | 无 | Android 前台服务 | 部分。流式中向 iOS 申请后台执行时间，时长由系统决定；回前台重放原生缓存，连接确实断开时保留内容并提供「继续写」 |

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

需要装有完整版 Xcode 和 iOS 平台的 Mac。仓库里已经有 Tauri iOS 配置、`fastlane/Fastfile`，以及会打出未签名 IPA 和模拟器包的 GitHub Actions。

准备：Xcode 16 或更新、仓库固定的 Rust 1.99.1、Node.js 22、pnpm 10。

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

## 验证状态

本轮 UI 开发版（尚未重新打 iOS 包）：

- `pnpm check`：类型检查、ESLint、单元测试、Vite 生产构建通过。覆盖正则角色 / 作用域 / 深度 / 导入、语音协议 / 音频格式、审批回写与断线、RAG 实际字段和 Markdown、旧数据补默认值、图片持久化及弹层退出时序。
- 模型与导航验收：Mac WKWebView 390pt 窗口读取 380 个模型，关键词搜索与回车选中完整 ID、最近选择、Agent 继承、两级 Escape；重开 App 后仍能直接使用目录缓存。自动化测试检查列表最多挂载 12 行，以及慢请求、刷新失败、连接切换与旧数据兼容。
- Rust Mac 主机测试 5 项通过；原生 Mac QA App 实际运行了新增语音和审批接口。
- Mac WKWebView 390pt 窗口：图片头像导入保存，自选壁纸导入、主题切换、遮罩与模糊；VChat / ST 正则导入、上下文发送副本及已有消息恢复原文；SoVITS 二进制音频和 MiMo SSE 音频的播放 / 进度 / 暂停；聊天气泡朗读；VCPLog 审批发出到服务端回执；完整长 RAG、表格、分数和来源渲染。使用只监听本机的合成协议服务，音频为验收测试音。
- 本轮没有连接用户的真实 TTS / VCPToolBox 服务，也没有在 iPhone 上复验新改动。真实音色质量、真机键盘和相册权限、后台语音行为，随下一轮 iOS 验收确认。

此前 `a9cdc07` 的 GitHub iOS 构建已成功，产出模拟器包及未签名 IPA；该包包含工具围栏渲染修复，不包含本轮 UI 开发版的新能力。当前不把旧 IPA 作为新版交付。

Rust 壳可用 `cargo test --lib --manifest-path src-tauri/Cargo.toml --locked` 检查。后台执行时间由 iOS 决定，应用不承诺无限后台流；重回前台时补齐原生流，已断开时保留内容并提供继续写。
