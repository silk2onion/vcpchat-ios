<div align="center">

<img src="docs/assets/vchat-cover.png" width="100%" alt="VChat for iOS — 你的 Agent，随身同行。" />

**连接你的 VCP，把 Agent、对话与工作资料带在身边。**

SwiftUI 原生客户端，为 iPhone 上的日常聊天与多 Agent 协作而设计。

<img alt="iOS 17 及更新版本" src="https://img.shields.io/badge/iOS-17%2B-183D38?style=flat-square&amp;logo=apple&amp;logoColor=white" />
<img alt="SwiftUI 原生界面" src="https://img.shields.io/badge/UI-SwiftUI-418577?style=flat-square" />

[**下载 VChat**](https://github.com/silk2onion/vcpchat-ios/releases/latest)　·　[功能介绍](#功能介绍)　·　[快速开始](#快速开始)　·　[桌面与文件](#连接你的工作空间)　·　[从源码运行](#从源码运行)

</div>

---

## 功能介绍

**会话**管理日常对话，**通讯录**管理 Agent 与群聊，**发现**查看 VCP 动态，**我**集中管理资料、文件、同步与设置。

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>💬 聊天与话题</h3>
      <p>发送文字、照片和文件，实时接收流式回复。每位 Agent 和群聊都有独立话题与草稿，切换话题时回复继续接收。</p>
      <p>支持搜索历史、编辑消息、继续写、重新生成与 Markdown 导出，聊天记录保存在本机。</p>
    </td>
    <td width="50%" valign="top">
      <h3>👥 Agent 与群聊</h3>
      <p>为 Agent 设置名字、头像、系统提示词、模型与音色，将常用角色设为主 Agent。</p>
      <p>多个 Agent 可加入同一群聊，保留各自身份，按点名、轮流、随机或全员回复的方式参与对话。</p>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>✨ 富内容与工具卡片</h3>
      <p>阅读 Markdown、代码、公式与 Mermaid 图表，查看图片、GIF 和视频；HTML 气泡支持动画与交互。</p>
      <p>工具请求、执行结果、思考链与日记以可展开卡片呈现，正文与执行过程分开阅读。</p>
    </td>
    <td valign="top">
      <h3>🔄 桌面同步</h3>
      <p>连接桌面 VCPChat，同步 Agent、群组、话题、消息与头像，在手机上接着聊。</p>
      <p>支持只拉取桌面内容或双向同步，保留手机原有记录，并提供同步恢复点。</p>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>📂 文件、笔记与日记</h3>
      <p>导入、预览、分享文件，连接工作文件夹与服务器文件；创建本机笔记，搜索和编辑服务器日记。</p>
      <p>可为 Agent 授予目录访问权限，通过移动版 FileOperator 在手机前台运行时读写授权文件。</p>
    </td>
    <td valign="top">
      <h3>🎧 语音朗读</h3>
      <p>连接 SoVITS v2ProPlus 或 MiMo TTS，把助手回复读出来。不同 Agent 可使用各自的音色、语速与导演提示词。</p>
      <p>支持音色试听、长文本朗读，以及播放、暂停、继续和停止。</p>
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>🔔 通知、审批与 RAG</h3>
      <p>在通知中心查看 VCPLog 与工具执行动态，检查待审批操作的命令、参数和变更预览，选择允许或拒绝。</p>
      <p>RAG 监视器展示检索来源、分数、标签与正文，也可查看记忆检索、思考链和 Agent 会话事件。</p>
    </td>
    <td valign="top">
      <h3>🎨 个性化与数据管理</h3>
      <p>选择主题、自定义壁纸与动态头像，调整回车发送或换行，以及代码、公式、图表和 HTML 的显示。</p>
      <p>全局与 Agent 专属正则可处理显示和发送内容，支持配置导入导出；聊天记录可备份、恢复，连接密钥存入系统钥匙串。</p>
    </td>
  </tr>
</table>

---

## 快速开始

### 1. 安装到 iPhone

前往 [Releases](https://github.com/silk2onion/vcpchat-ios/releases/latest) 下载 IPA，使用 AltStore 等侧载工具签名安装。需要 **iOS 17 或更新版本**。

更新时沿用原签名账号与应用标识，直接覆盖安装，保留已有数据。

### 2. 连接 VCP

准备一个手机可访问的 VCP 服务，打开 **我 → 设置 → 服务器与模型**：

| 项目 | 填写内容 |
| --- | --- |
| 服务器 | 你的 VCP 服务地址 |
| 聊天 API Key | 对应服务的聊天密钥 |
| 模型 | 输入模型 ID，或点击“鉴权并读取模型”后选择 |
| 接口 | 连接 VCP 时选择“VCP 工具模式”；其他兼容服务选择“OpenAI 兼容” |

已有桌面配置？点击 **导入桌面 VCPChat 连接…**，选择桌面的 `AppData/settings.json`，也可导入手机配对文件。

### 3. 开始对话

在 **通讯录** 点 ＋ 创建 Agent，设置名字、提示词和模型，点开即可聊天。将常用角色设为主 Agent，就能从 **会话** 顶部快速找到它。

想让多个角色一起参与，在通讯录中创建群聊并选择成员。聊天顶部可新建或切换话题；长按消息可复制、编辑和分享，对话菜单可导出 Markdown。

## 连接你的工作空间

### 桌面同步

先在桌面 VCPChat 启用 **VCPMobileSync**，再进入 **我 → 桌面同步**，填写插件提供的 HTTP 地址、WebSocket 地址和同步 Token。默认端口分别为 **5974** 与 **5975**。

首次连接选择 **只拉取桌面内容**，导入 Agent、群组、会话与头像，保留手机原有记录。需要将手机上的修改和删除写回桌面时，选择 **双向同步**。同步后可从本机恢复点找回此前内容。

### 文件与笔记

进入 **我 → 文件**，导入、预览和分享文件，或将文件加入聊天。

- **连接文件夹**：选择工作目录，直接浏览和编辑文件；为 Agent 单独授予只读或读写权限。
- **服务器文件**：连接 VCP FileOperator，管理远端目录与文件；下载原件时配置 File Key 和分发目录。
- **笔记与日记**：在 **我 → 笔记** 记录想法；连接服务器日记时，使用日记管理员账号。

需要 Agent 操作手机文件时，可在连接文件夹中启用 **移动版 FileOperator**，让已授权的目录成为 VCP 分布式节点。手机节点在 App 前台运行。

### 通知与检索

在连接设置中填写 **VCPLog Key** 并连接 WebSocket。点击聊天页的通知按钮，或进入 **我 → 通知中心**，即可查看实时日志、RAG 来源与检索正文，以及需要确认的工具操作。

## 按你的习惯使用

- **外观**：在 **设置 → 外观** 选择主题与壁纸，也可使用自己的照片或 GIF。
- **语音**：在 **设置 → 语音与朗读** 连接 SoVITS v2ProPlus 或 MiMo TTS，为不同 Agent 设置音色，点击消息扬声器开始朗读。
- **正则**：在 **设置 → 全局正则** 管理显示与上下文规则，支持 VChat 和 SillyTavern 配置导入；Agent 也可使用专属规则。
- **输入与渲染**：在设置中选择回车发送或换行，在高级渲染中调整代码、公式、图表与 HTML 气泡的显示。

聊天记录保存在本机，连接密钥保存在系统钥匙串。进入 **我 → 设置 → 本机数据**，可备份和恢复聊天记录。

---

## 从源码运行

使用 **Xcode 16 或更新版本** 打开 `VChat.xcodeproj`，选择 **VChat** 和 iPhone 模拟器运行。连接自己的 iPhone 时，在签名设置中选择开发团队。

也可通过 [GitHub Actions · Native iOS Build](https://github.com/silk2onion/vcpchat-ios/actions/workflows/native.yml) 构建模拟器 App 与未签名 IPA。

在 **macOS 14+**、**Swift 6** 环境下，可从项目目录运行 Mac 客户端：

```sh
swift run VChatMac
```

## 许可与致谢

VChat 以 [CC BY-NC-SA 4.0](LICENSE) 发布。Copyright 2026 VCPChat iOS contributors。

感谢 [VCPMobile](https://github.com/MRiecy/VCPMobile)、[VCPChat](https://github.com/lioensky/VCPChat) 与 [VCPToolBox](https://github.com/lioensky/VCPToolBox)。第三方组件与许可见 [开源致谢](docs/ACKNOWLEDGEMENTS.md)。

<p align="center"><img src="Configuration/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="48" height="48" alt="VChat" /><br /><strong>你的 Agent，随身同行。</strong></p>
