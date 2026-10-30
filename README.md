# VCPChat iOS

**把你的 VCP 工作台带到 iPhone。**

VCPChat iOS 是连接自有 VCPToolBox 服务的多 Agent 聊天客户端。与不同 Agent 开展独立对话，让多个 Agent 参与同一场讨论，把桌面历史、工具审批、检索信息和文件放进随身的工作台。

[开始使用](#quick-start) · [桌面同步](#sync) · [文件管理](#files) · [开发](#development) · [构建与安装](#build)

## 功能

- **多 Agent 会话**：为每位 Agent 设置头像、人设、模型与声音，按话题组织对话，随时切换主 Agent。
- **群聊协作**：组合不同 Agent，通过点名、轮流、随机或依次回复开展讨论。
- **富消息呈现**：支持 Markdown、代码、公式、Mermaid、HTML 交互气泡、图片与视频，清晰呈现思考、工具调用和执行结果。
- **语音与文本处理**：接入 SoVITS 或 MiMo 朗读回复，使用全局或 Agent 正则整理显示与上下文。
- **通知与审批**：集中查看 VCPLog、工具审批和 RAG 信息流，追踪检索来源、知识片段与 Agent 活动。
- **桌面同步**：同步桌面 Agent、群组、会话、消息和头像，支持增量写回与本机恢复点。
- **文件与笔记**：管理本机附件和服务器文件，记录本机笔记，读写服务器日记。
- **个性化界面**：选择主题、壁纸和头像，调整渲染与输入习惯。

<a id="quick-start"></a>
## 开始使用

打开 **我 → 设置 → 服务器与模型**，填写连接信息：

| 配置 | 示例或说明 |
| --- | --- |
| VCP 服务器 URL | 手机可访问的地址，如 `http://192.168.1.8:6005` |
| API Key | 聊天服务的 API Key |
| 接口 | OpenAI 兼容，或 VCP 工具模式 |
| 默认模型 | 刷新模型列表后选择，也可直接填写模型 ID |

点 **测试连接并刷新模型**，选择模型后回到“会话”，打开助手即可开始聊天。

**OpenAI 兼容**使用 `/v1/chat/completions`；**VCP 工具模式**使用 `/v1/chatvcp/completions`，由 VCP 后端处理工具调用。服务器 URL 支持基础地址和完整聊天路径。

## Agent 与会话

### 创建你的 Agent

进入 **通讯录 → ＋**，设置名字、头像、简介、系统提示和模型，保存后开始对话。已有 Agent 可从右侧菜单编辑，也可在聊天顶部点头像打开资料。

系统提示决定角色与工作方式；模型留空时继承全局设置。每位 Agent 还可以配置专属音色、朗读提示词和正则规则。

在 Agent 资料中选择 **设为主 Agent**，即可将它固定在会话页顶部。

### 按话题组织对话

点会话页的＋新建话题，使用聊天顶部的历史按钮切换话题。每个话题分别保留草稿和待发送附件，生成中的回复会在切换话题后继续接收。

聊天支持图片和文本附件。回复中的思考、工具调用与结果分别呈现；可复制消息、朗读正文，也可停止生成或继续中断的回复。

### 让多个 Agent 参与讨论

在通讯录的群聊区域创建群聊，选择成员和发言方式：

- **@点名，否则轮流**：指定成员回复，或按顺序轮流发言。
- **轮流一位**：每轮由一位成员回复。
- **随机发言**：每轮随机选择一位成员。
- **仅点名发言**：用 `@名字` 邀请成员参与。
- **每位依次回复**：所有成员依次加入讨论。

## 通知与信息流

打开 **我 → 设置 → 日志通道**，填写 VCP WebSocket 地址和 WebSocket Key，点“连接日志通道”。例如：

```text
VCP WebSocket URL: ws://192.168.1.8:6005
VCP WebSocket Key: 服务器配置的日志密钥
```

聊天右上角的铃铛和 **我 → 通知中心** 都可打开信息面板：

- **通知**：查看待审批请求、参数和变更预览，允许或拒绝工具调用，并查看处理回执。
- **VCPLog**：查看工具执行和服务运行日志。
- **RAG 监视器**：阅读检索问题、知识片段、来源与分数，以及元思考、Agent、记忆和梦境事件。

<a id="sync"></a>
## 桌面同步

### 连接桌面 VCPChat

1. 在桌面端启用 [VCPMobileSync](https://github.com/lioensky/VCPChat/tree/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync)，设置 `MobileSyncToken`，启动 VCP 分布式服务器。
2. 在手机打开 **我 → 桌面同步**，填写连接信息：

   | 配置 | 示例 |
   | --- | --- |
   | 桌面 HTTP 地址 | `http://192.168.1.8:5974` |
   | 同步 WebSocket 地址 | `ws://192.168.1.8:5975/` |
   | Mobile Sync Token | 桌面端配置的 `MobileSyncToken` |

3. 选择 **从桌面拉取**，点“开始同步”。

5974 为桌面分布式服务的默认 HTTP 端口，5975 为同步 WebSocket 默认端口；自定义端口时填写对应值。手机与桌面使用可互通的网络。

### 在手机与桌面之间继续工作

首次拉取会建立独立的桌面来源，现有本机会话继续保留。在同步会话中新增消息、创建话题或修改 Agent 资料后，选择 **双向同步** 写回桌面。

每次完成同步会保存本机恢复点。需要还原手机上的同步资料时，选择 **恢复到上次同步前**。

同步消息中的附件可在文件页导入原件，或从服务器下载；文件库会按内容关联到对应消息。

<a id="files"></a>
## 文件与笔记

### 本机附件

进入 **我 → 文件 → 本机附件**，导入文件或收集聊天附件，查看图片和文本，并将原文件导出到系统中。重复内容自动归入同一份文件；同名导出另存副本，保留原件。

Mac 上点“查看导出位置”打开 Finder；iPhone 上可在“文件 → 我的 iPhone → VCPChat → VCPChat Exports”找到导出内容。

### 服务器文件

进入 **文件 → 服务器文件 → 连接与目录设置**：

1. 使用“服务器与模型”中已配置的 ToolBox 地址与 API Key。
2. 文件工具名称填写 `ServerFileOperator`，或你的自定义工具名。
3. 读取服务端允许目录，选择浏览起点；也可填写服务器绝对路径。

随后即可浏览目录、上传文件、新建文本或文件夹、读取文档、重命名、复制、移动和移入回收站。文件夹右侧菜单提供目录管理操作。

**下载原文件**使用 `ImageFileServer`：在连接设置中填写 `File_Key` 和服务端 `file/` 目录映射，再将分发目录中的文件下载到本机附件库。

### 笔记与日记

**我 → 笔记 → 本机** 用于新建、编辑和保存个人笔记。

使用服务器日记时，在 **设置 → 身份与日记** 填写管理员用户名和密码，再进入 **笔记 → 服务器日记**，选择文件夹，即可搜索、阅读、编辑和保存日记。

## 声音、外观与文本

### 语音朗读

在 **我 → 设置 → 语音与朗读** 选择语音服务，填写地址和 Key，选择音色后试听。

| 服务 | 连接方式 |
| --- | --- |
| SoVITS · VChat 兼容 | 使用 v2ProPlus 服务的基础地址，如 `http://192.168.1.8:8000`，刷新音色后选择 |
| MiMo · 网络语音 | 填写服务地址、API Key、语音模型和音色；可用导演提示词调整语气与节奏 |

点回复下方的扬声器开始朗读，播放器提供进度、暂停、继续和停止。Agent 资料中的声音设置可覆盖全局音色。

### 正则规则

在 **设置 → 全局正则** 管理共用规则，在 Agent 资料中设置专属规则。支持 VChat / SillyTavern JSON 导入、编辑、排序、启停、试替换与导出。

规则可分别用于消息显示和发送上下文，保存的原文保持不变。

### 外观与输入

在 **设置 → 外观** 选择墨色、纸色或极光主题，搭配内置或自选壁纸。**高级渲染**可调整代码、公式、图表、HTML 和媒体的显示效果。

**Enter 发送消息**可在设置中切换；⌘/Ctrl+Enter 用于发送，Shift+Enter 用于换行。

<a id="development"></a>
## 开发

技术栈：**Tauri 2 · Vue 3 · TypeScript · Rust**。

环境：Node.js 22、pnpm 10。原生开发使用 rustup，仓库通过 `rust-toolchain.toml` 固定 Rust 1.99.1。平台依赖见 [Tauri 开发环境](https://v2.tauri.app/start/prerequisites/)。

在项目目录执行：

```bash
corepack enable
pnpm install
pnpm dev
```

浏览器访问 [http://127.0.0.1:43123](http://127.0.0.1:43123)。

运行 Mac 原生应用：

```bash
pnpm tauri dev
```

### 本地演示

另开终端运行演示服务：

```bash
pnpm mock-server
```

在“服务器与模型”填写 `http://127.0.0.1:43124`，API Key 填 `local-demo`，模型选 `vcp-demo`，即可体验流式回复、思考与工具卡片。日志演示地址为 `ws://127.0.0.1:43124`，Key 同样填 `local-demo`。

### 检查与构建网页

```bash
pnpm check
cargo test --lib --manifest-path src-tauri/Cargo.toml --locked
```

`pnpm check` 包含类型检查、lint、测试和网页构建；`pnpm build` 的网页产物位于 `dist/`。

<a id="build"></a>
## 构建与安装

### 构建 iOS 应用

需要 macOS、完整版 Xcode 16 或更新，以及 Xcode 中的 iOS 平台与模拟器组件。应用最低系统版本为 iOS 16.0。

选择 Xcode 开发目录：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

在项目目录安装依赖并构建：

```bash
pnpm install
bash scripts/build-ios-simulator.sh
bash scripts/build-unsigned-ipa.sh
```

脚本自动完成 Apple 工程初始化、目标安装与 plist 配置。

| 产物 | 路径 |
| --- | --- |
| 模拟器 App（Apple Silicon） | `src-tauri/gen/apple/build/arm64-sim/VCPChat.app` |
| 未签名设备 IPA | `dist-ios/VCPChat-unsigned.ipa` |

### 安装到 iPhone

将 IPA 导入 [AltStore Classic](https://faq.altstore.io/) 或 [Sideloadly](https://sideloadly.io/)，完成签名与安装。也可在 Xcode 中打开生成的 `src-tauri/gen/apple/*.xcodeproj`，选择自己的开发 Team 和设备后运行。

更新已有安装时，沿用相同的签名身份与 Bundle ID：`app.vcpchat.ios`。

### GitHub Actions

在仓库的 **Actions → iOS → Run workflow** 选择分支启动构建。完成后，从 `VCPChat-iOS-products` 下载模拟器 App 和未签名 IPA；构建日志保存在 `VCPChat-iOS-logs`。

## 致谢与许可

本项目参考并适配了 [VCPChat](https://github.com/lioensky/VCPChat)、[VCPMobile](https://github.com/MRiecy/VCPMobile) 与 [VCPToolBox](https://github.com/lioensky/VCPToolBox) 的相关协议与实现。上游版本及素材说明见 [NOTICE.md](NOTICE.md)。

采用 [CC BY-NC-SA 4.0](LICENSE) 许可。第三方依赖遵循各自许可。
