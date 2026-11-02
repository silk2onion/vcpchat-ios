<div align="center">

<img src="docs/assets/vchat-cover.png" width="100%" alt="VChat for iOS — 你的 Agent，随身同行。" />

**连接你的 VCP，把 Agent、对话与工作资料带在身边。**

SwiftUI 原生客户端，为 iPhone 上的日常聊天与多 Agent 协作而设计。

<img alt="iOS 17 及更新版本" src="https://img.shields.io/badge/iOS-17%2B-183D38?style=flat-square&amp;logo=apple&amp;logoColor=white" />
<img alt="SwiftUI 原生界面" src="https://img.shields.io/badge/UI-SwiftUI-418577?style=flat-square" />

[**下载 VChat**](https://github.com/silk2onion/vcpchat-ios/releases/latest)　·　[快速开始](#快速开始)　·　[桌面与文件](#连接你的工作空间)　·　[从源码运行](#从源码运行)

</div>

---

## 一个随身的 Agent 工作空间

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>💬 随时接着聊</h3>
      流式回复、独立话题与本机历史。发送文字、照片和文件，搜索、编辑或导出你的对话。
    </td>
    <td width="50%" valign="top">
      <h3>👥 你的 Agent 团队</h3>
      自定义头像、提示词与模型，选择主 Agent；把不同角色加入群聊，按点名、轮流或随机方式协作。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>🔄 桌面与手机衔接</h3>
      从 VCPChat 同步 Agent、群聊与历史会话，把桌面的对话带到手机，继续交流。
    </td>
    <td valign="top">
      <h3>📂 资料就在手边</h3>
      管理本机与服务器文件，连接工作文件夹，随手记录笔记、查阅和编辑服务器日记。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h3>✨ 回复不止于文字</h3>
      Markdown、代码、公式、Mermaid 图表与交互式 HTML 气泡，让复杂内容清楚呈现。
    </td>
    <td valign="top">
      <h3>🎧 听回复，看动态</h3>
      用 SoVITS 或 MiMo 朗读消息，在通知中心处理工具审批、查看 VCPLog 与 RAG 检索结果。
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
