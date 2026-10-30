# 桌面同步与文件管理：上游机制及本 iOS 应用的接入方向

核查日期：2026-10-30。阶段：只读源码调查，未连接真实同步服务。

## 结论：复用同步协议，文件功能走另一条通道

**建议保留本 iOS 应用的界面与 Repository，增加官方同步协议适配和持久化元数据；文件管理独立接入 ToolBox 已有工具入口。不要用桌面数据库覆盖手机数据库，也不要把“附件出现在历史里”当作文件已下载。**

- 官方已有桌面插件与移动端同步引擎，并非只能自行设计同步服务。
- 会话、Agent、群组和头像可复用；用户完整资料、附件原文件、常驻自动入站不是同一套已交付能力。
- 两个最新默认分支存在群组 DTO 漂移，不能仅凭双方都写 Wire 1.5 就宣称兼容。
- 原版 Mobile 已有一次官方 iOS 编译归档成功记录，但文件选择、原生文件打开等仍未接齐。

## 1. 本次固定的版本与来源

| 对象 | 固定版本 | 用途 |
|---|---|---|
| [MRiecy/VCPMobile][mobile-commit] | `a8482b607df13a74e7f8d63a2b0f751221eaaf1a`，2026-10-16 | 最新 `main`；Tauri/Vue/Rust 原版移动端 |
| [lioensky/VCPChat][chat-commit] | `1fadcf1531151cd7c5070fc1737d944133918dba`，2026-10-30 | 最新 `main`；同步插件 `2.0.0`、Wire `1.5` |
| [lioensky/VCPToolBox][toolbox-commit] | `0c919a3b16f10003f7bea4238a3863e1200cf690`，2026-10-30 | 服务端文件工具、文件分发和直接工具调用 |
| 本 iOS 应用 | `95adb10291cb1bf7bef450d063a0bd7c47a76b99` | 当前小型重写版，不等于原版 Mobile |
| 本机 macOS VCPChat | `40c0d3cf` | 用户本地改版；仅作源码对照，不代替官方版本 |

本机同步插件未发现新增 Wire/DTO 数据类型，不能把它当作另一套协议。

Mobile README 链接的是 [MRiecy/VCPChat 分支][fork-group]，不是本次指定的 lioensky 最新版。该分支最新 `main` 为 `fb66a52dd038a6fd147ee91cd1a39fe17555867e`（2026-09-05）；其群组字段较接近 Mobile，但不能用它证明 lioensky 最新版兼容。

## 2. 官方同步怎样运行

### 入口、端口与身份

桌面入口是 `VCPDistributedServer/Plugin/VCPMobileSync/index.js`，由 VCPChat 的分布式服务器加载。默认采用 CDS 中央索引，显式关闭后才使用 Legacy 索引；CDS 失败时只开放诊断 WebSocket，**不自动切到 Legacy**。[初始化与分模式][c-init]

| 通道 | 默认地址形式 | 身份 |
|---|---|---|
| 同步控制面 | `ws://桌面地址:5975/` 或 `/ws-sync` | URL 查询参数 `token=MobileSyncToken` |
| 同步数据面 | `http://桌面地址:5974/api/mobile-sync/*` | `Authorization: Bearer <MobileSyncToken>` |
| ToolBox 直接文件操作 | `POST /v1/human/tool`，使用 ToolBox 自己的地址/端口 | ToolBox 的 `serverKey` |
| 文件/图片分发 | `/pw=<key>/files/...`、`/pw=<key>/images/...` | 分别为 `File_Key`、`Image_Key` |

5974 是桌面分布式 HTTP 服务的默认端口，不是 ToolBox 聊天服务的固定端口；5975 是同步插件独立监听端口。WebSocket 代码监听 `0.0.0.0`，仅接收上述两种路径；HTTP 同步路由独立校验 Token。[桌面部署说明][c-readme] [WebSocket 实现][c-ws] [HTTP 实现][c-auth]

### 数据流

1. 手机设置保存 HTTP URL、WebSocket URL 和同步 Token，在同步面板调用 `start_manual_sync`。首帧交换 `VERSION_CHECK` / `VERSION_ACK`，精确匹配 Wire `1.5`，包版本用于诊断。[手机入口][m-start] [版本实现][m-version]
2. 构建 Owner 清单，并独立处理 Avatar 清单；以 `configHash`、Owner 内容根和时间戳决定拉取、推送或删除，再细化到发生变化的 Owner/Topic。[清单生成][m-manifest] [桌面裁决][c-manifest]
3. Topic 内容根不一致时做消息级差分；使用复合身份 `(ownerType, ownerId, topicId, msgId)`，返回待拉消息、是否推送该话题、消息墓碑。[消息裁决][c-diff]
4. HTTP `/entities/pull|push` 传配置 DTO；`/messages/pull|push` 逐 Topic 传 NDJSON；`/avatars/pull|push` 单独传头像字节。**没有附件原文件上传/下载路由。**[实际路由][c-routes]
5. Mobile 把结果写入 SQLite，经写队列收尾、重算派生状态，收到匹配的最终 ACK 后才完成；前端随后重新加载数据。[写入与收尾][m-finish] [界面重载][m-reload]

桌面默认 CDS 维护中央 SQLite 索引，普通聊天兼容真源仍是 Owner 配置、`UserData/{ownerId}/topics/{topicId}/history.json` 和头像文件；Legacy 改用插件 `sync_state_v2.db` 与文件监听。同步不是把整份桌面库下载到手机。[后端模式与真源][c-readme]

## 3. 实际传什么、不传什么

| 数据 | 代码实际覆盖 | 对本 iOS 的意义 |
|---|---|---|
| Agent | 名称、系统提示、模型、温度、上下文/输出限制、流式开关的白名单 | 不是整个联系人配置；音色、正则及其他桌面扩展字段不能假定同步 |
| 群组 | 成员 ID、发言模式、提示、标签和统一模型等白名单 | 当前两端字段有漂移，见下一节 |
| Topic | 稳定身份、名称、创建时间、配置哈希、更新时间；Agent Topic 另含 locked/unread | 可导入历史话题，不应以名称重新生成身份 |
| 消息 | 文本、角色、时间、作者/Agent/Group/Topic 信息、完成原因和附件 DTO | 不是复制所有本地渲染缓存/瞬态状态 |
| 用户资料 | 只见 `user/user_avatar` 作为头像身份 | 未见用户名、完整用户设置的同步实体 |
| 头像 | Agent、Group、User 的独立字节 Pull/Push | 与消息附件的边界不同，可真正跨端取得图片 |
| 附件 | 名称、MIME/type、大小、内容 SHA-256；可带提取文本、imageFrames、创建时间 | 原文件、缩略图和本机路径不随同步传输 |

依据：[Mobile DTO][m-dto]、[桌面 Agent 白名单][c-agent]、[桌面群组白名单][c-group]、[头像路由][c-avatar]。因此“只传元数据”仍可能包含已提取的文档文本或帧字符串，不等于只传文件名。

Mobile 收到附件 DTO 后先查询本机 CAS：已有真实文件则标为 `ready`；不存在则保存空路径并标为 `desktop_only`。界面明确显示“桌面专用附件 · 未同步文件内容”，且禁止直接打开；以后独立导入同 hash 文件可以恢复可用状态。[持久化判定][m-cas] [附件界面][m-preview] [本地登记][m-file-register]

### 两个最新分支的具体兼容缺口

lioensky 桌面 `extractGroupDTO` 总会包含 `enableContextMessageWindow`、`contextMessageWindowSize`；Mobile `GroupSyncDTO` 没有这两字段并启用 `deny_unknown_fields`，`EntityPullData` 又直接用该 DTO 解码。[桌面字段][c-group] [Mobile DTO][m-dto] [解码类型][m-entity-type]

**源码推断：这组固定版本发生群组 Pull 时，会有未知字段拒收风险；即使忽略未知字段，跨端 canonical/hash 字段也必须一起对齐。** 尚未执行跨端复现。实现前应按这组具体 DTO 形成兼容契约，而不是照抄版本号；桌面现有更新函数按白名单修改已有配置，本 iOS 也应保留不认识的上游字段。[桌面字段应用][c-group]

## 4. 删除、冲突、断线与自动话题

- **删除**：跨端使用明确墓碑，不把某条 live 清单缺项当作删除。Owner/Topic/Avatar 和消息分别参与删除裁决；现有墓碑优先于对应 live 数据，并非简单按“最后编辑时间”复活。[实体删除裁决][c-manifest] [消息删除裁决][c-diff]
- **冲突**：两条 live 实体的配置哈希不同，以较新 `updatedAt` 为准；时间相同的实体/头像偏向桌面。live 消息同时间再比较消息 hash 字典序，较大者胜出；不是字段级合并。[实体裁决][c-manifest] [CDS 消息裁决][c-cds-diff]
- **断线补拉**：当前手动会话最多自动重试 3 次；每次重连建立新的 attempt 和 Owner 集合，重新比对，已提交写入先排空并修复状态。不是按永久服务端事件游标断点续传。[重试][m-retry] [attempt 重建][m-attempt] [中断收尾][m-interrupt]
- **桌面新话题**：已落盘并进入桌面索引的新话题可以在下一次同步清单中被发现；原版 Mobile 成功同步后退出会话循环，没有由此证明“服务端新建话题后手机常驻自动生成会话”。[清单缺项拉取][c-manifest] [完成即退出][m-interrupt]
- **iOS 后台**：原版实现明确在后台停止同步，并要求前台手动启动；不能直接承诺杀后台后持续收取话题。[iOS 生命周期][m-lifecycle] [前台入口][m-start]

README 的“后台保持实时或手动增量”不能替代上述当前控制流；VCPLog/VCPInfo 的事件显示也不是历史库同步通道。

## 5. 原版 Mobile 的“文件管理”其实是哪一层

原版的 `infra/file_manager.rs` 是**本机附件生命周期模块**：管理 CAS、缩略图、提取文本、缓存和本地路径，不是服务器磁盘文件浏览器。所核查 features 模块中未见独立 ServerFileOperator 文件管理页；现有可见入口主要是聊天附件选择、预览、移除与维护缓存。[文件目录与生命周期][m-file] [附件 UI][m-preview]

- Android：系统文件选择器 → Kotlin 暂存 → `register_local_file` → 本机 CAS/SQLite → 聊天附件卡。
- 非 Android HTML 导入：小于 2 MiB 走 `store_file`；较大文件调用 `prepare_vcp_upload`，由 WebView 上传至 **手机自身 `127.0.0.1:随机端口`**，Rust 再登记 CAS。这不是向 ToolBox 服务器上传。[前端导入分流][m-import] [回环上传实现][m-upload]
- 图片/文本可在应用内预览；其他类型 Android 可交给系统应用。iOS 的 `pick_file`、原生打开仍有 `not_implemented` 路径，用户头像选图也明确未接入。[原生能力][m-picker] [文件打开][m-file-open] [用户头像界面][m-profile]

### 原版 iOS 已可编译到什么程度

源代码已有 Swift 插件、iOS 配置、最低系统版本 **26.0** 和手动 device-archive workflow。[iOS 配置][m-ios-config] [构建入口][m-ios-workflow]

本应用当前 [tauri.conf.json](/Users/zhaoyuanhao/Documents/vchat%20ios/src-tauri/tauri.conf.json#L29-L31) 明确配置 `minimumSystemVersion: "16.0"`。这是上游与本应用的配置差异；适配同步层不应顺带将本应用最低版本抬到 26.0。

同一固定 SHA 的官方 [G1 run 38884164944][m-ios-run] 在 2026-10-16 成功：依赖安装、unsigned device archive 构建和归档上传步骤均成功，日志记录 `.xcarchive` 及归档 ZIP 上传。README“尚未取得 Apple 构建结果”已落后于这次 CI 证据。当前 API 返回该 run 无现存 artifact，未取到包检查；也未见这次证据证明已签名 IPA、安装成功或文件/同步真机验收。[构建产物定义][m-ios-readme]

## 6. ToolBox 可复用的是文件工具，不是聊天历史库

**优先复用 `POST /v1/human/tool` 给文件按钮调用工具，不必先造一套新 RPC，也不必让模型代按按钮。** 请求为 `text/plain` 的 `TOOL_REQUEST` 块，服务端直接调用 `pluginManager.processToolCall` 并返回 JSON。[直接工具入口][t-human]

| 能力 | 能复用 | 边界 |
|---|---|---|
| `ServerFileOperator`（目录名 FileOperator） | 列允许目录、列目录、读取、属性、搜索、复制/移动/重命名/删除等 | 操作服务器或目标节点文件，不赋予 iPhone 任意磁盘权限 |
| `WriteFile` | 指定 encoding 写文件；`base64` 路径理论可写二进制 | 现有代码按解码大小限额；不是分块、断点续传或完整网盘上传协议 |
| `ImageFileServer` | 从项目 `image/`、`file/` 分发字节 | 不是任意路径浏览，也不自动把桌面历史附件搬入这些目录 |
| `FileFetcherServer` | 按请求 IP 找已注册节点，调用 `internal_request_file` 取 base64 并缓存至服务端 | 是服务端取源文件，不是手机历史附件自动下载；桌面 `file://` 不能原样给手机打开 |

依据：[工具 manifest][t-manifest]、[WriteFile][t-write]、[字节分发][t-static]、[节点取文件][t-fetch]。

`DeleteFile` 当前代码调用目标设备的 `trash`，返回“已移入回收站”，并非直接 unlink；真实服务上的依赖与回收站支持仍未验证。[删除实现][t-delete]

若界面承诺“仅指定目录”，适配边界必须真的约束根目录：当前 FileOperator 的允许目录为空时放行全部路径；绝对路径 ReadFile/FileInfo 还可绕过该目录列表，不能直接将这份配置称为严格隔离。[实际路径判定][t-path]

`/admin_api/agents` 操作 ToolBox 后端的 Agent 提示词文件，不是桌面联系人配置；`/admin_api/dailynotes` 和知识文件管理也不是 VCPChat 话题/消息库。[Agent 管理源码][t-agent]

鉴权应分别保存并明确用途：ToolBox `serverKey`、桌面 `MobileSyncToken`、`Image_Key`/`File_Key`、管理员 Basic 身份不能混用。[ToolBox Bearer][t-auth] [同步 Bearer][c-auth] [文件 Key][t-static]

## 7. 当前应用的接入

入口为“我 → 桌面同步”和“我 → 文件”。保留 IndexedDB、既有数据表和旧记录身份；仅新增文件表与同步元数据。桌面导入使用来源 UUID + owner 类型/ID + topic ID 的复合身份，解决不同 Agent 的相同原始话题/消息 ID 冲突。

- `src/sync/`：原版 canonical/hash、Wire 1.5 握手、清单与差分、实体批次、消息 NDJSON、头像二进制与最终 ACK。原版 Mobile 的 SQLite 引擎没有整包搬入；同步 shadow 保存未知 DTO 字段、版本与墓碑，投影到现有 Repository。
- `src/stores/sync.ts`：默认拉取、显式双向、取消、未完成不应用、原子恢复点。提交时重新检查本机记录；同步期间被编辑会整批拒绝。拉取不会盖掉本机未回写改动。成功后保留原主 Agent 的入口。
- `src/files/` 与 `FilesView.vue`：本机内容寻址文件库、原文件导出，以及原版 FileOperator 和 ImageFileServer 适配。服务器绝对路径只作为浏览起点，不宣称为服务器权限隔离。
- 附件原文件与历史同步分开；用户资料和连接设置保留在本机。已缓存原文件按 hash 关联到同步附件；未取回的附件保留“仅桌面”状态。

使用说明见 [README](/Users/zhaoyuanhao/Documents/vchat%20ios/README.md)。双向同步的远端操作逐项生效，本机提交是原子的，不能用本机恢复点撤销远端已经确认的写入。断线后手动重试对齐；当前不自动重试写回，也不把前台同步称作 APNs 推送或后台常驻节点。

## 8. 已取得证据与实际未验项

固定源码取证在 `/Users/zhaoyuanhao/CodexArtifacts/vcpchat-upstream-sync-20261030T144200Z/`。

接入与 Mac 验收在 `/Users/zhaoyuanhao/CodexArtifacts/vcpchat-sync-files-20261030T145651Z/`。使用固定版本的原版 VCPMobileSync、FileOperator、ImageFileServer 路由与脚本，运行在仅监听本机的隔离合成数据上；未访问用户真实桌面 AppData。协议回归覆盖原版 golden fixture、复合身份、旧 IndexedDB 升级、并发编辑保护、错误与取消、本机恢复、原文件去重和导出。实际原库联调包含拉取、重复同步、资料/消息写回、新话题创建与删除、文件上传/读取/改名/下载。

Mac WKWebView 已实际验证旧会话保留、拉取保护、双向新消息写回与重复同步，以及原文件读取、下载、本机导入去重和同名导出保留。截图与日志在上述归档目录。

尚未接用户真实桌面服务/CDS，也未在 iPhone 上验证本轮改动。当前未接 APNs、服务器主动新话题通知和 iOS 分布式插件常驻执行；按本轮要求不重新打 iOS 包。

[mobile-commit]: https://github.com/MRiecy/VCPMobile/commit/a8482b607df13a74e7f8d63a2b0f751221eaaf1a
[chat-commit]: https://github.com/lioensky/VCPChat/commit/1fadcf1531151cd7c5070fc1737d944133918dba
[toolbox-commit]: https://github.com/lioensky/VCPToolBox/commit/0c919a3b16f10003f7bea4238a3863e1200cf690
[fork-group]: https://github.com/MRiecy/VCPChat/blob/fb66a52dd038a6fd147ee91cd1a39fe17555867e/VCPDistributedServer/Plugin/VCPMobileSync/dto/group.dto.js#L8-L19
[c-init]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/index.js#L143-L233
[c-readme]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/README.md#L75-L135
[c-ws]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/transport/websocket.js#L90-L182
[c-auth]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js#L221-L256
[c-routes]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js#L282-L612
[c-avatar]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/transport/routes.js#L143-L164
[c-manifest]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/sync/manifest.js#L385-L479
[c-diff]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/sync/diff.js#L316-L389
[c-cds-diff]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/rust_chat_data_service/src/sync.rs#L1287-L1333
[c-agent]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/dto/agent.dto.js#L7-L55
[c-group]: https://github.com/lioensky/VCPChat/blob/1fadcf1531151cd7c5070fc1737d944133918dba/VCPDistributedServer/Plugin/VCPMobileSync/dto/group.dto.js#L7-L61
[m-start]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L3332-L3427
[m-version]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_version.rs#L1-L40
[m-manifest]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_pipeline/phase1_metadata.rs#L15-L148
[m-finish]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L2265-L2337
[m-reload]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src/core/stores/syncSession.ts#L443-L465
[m-dto]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_dto.rs#L39-L233
[m-entity-type]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_types.rs#L250-L257
[m-cas]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/persistence/db_write_queue.rs#L2164-L2208
[m-preview]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src/features/chat/attachment/AttachmentPreview.vue#L54-L151
[m-file-register]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/infra/file_manager.rs#L557-L615
[m-retry]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L495-L544
[m-attempt]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L1631-L1677
[m-interrupt]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L2865-L2935
[m-lifecycle]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/infra/lifecycle_controller.rs#L138-L170
[m-file]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/infra/file_manager.rs#L100-L198
[m-import]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src/core/stores/attachmentStore.ts#L284-L518
[m-upload]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/infra/high_speed_channel.rs#L27-L84
[m-picker]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/plugins/vcp-mobile/src/system.rs#L410-L435
[m-file-open]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/infra/file_manager.rs#L1163-L1204
[m-profile]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src/features/settings/components/UserProfileSection.vue#L41-L53
[m-ios-config]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/tauri.ios.conf.json#L1-L9
[m-ios-workflow]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/.github/workflows/ios-g1.yml#L29-L86
[m-ios-run]: https://github.com/MRiecy/VCPMobile/actions/runs/38884164944/job/116917778713
[m-ios-readme]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/ios/README.md#L47-L65
[m-pull-write]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_executor/pull_executor.rs#L619-L646
[m-secret-log]: https://github.com/MRiecy/VCPMobile/blob/a8482b607df13a74e7f8d63a2b0f751221eaaf1a/src-tauri/src/vcp_modules/sync/sync_service.rs#L1442-L1454
[t-human]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/server.js#L1253-L1303
[t-manifest]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/Plugin/FileOperator/plugin-manifest.json#L1-L45
[t-write]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/Plugin/FileOperator/FileOperator.js#L656-L673
[t-delete]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/Plugin/FileOperator/FileOperator.js#L1104-L1129
[t-static]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/Plugin/ImageFileServer/image-file-server.js#L471-L545
[t-fetch]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/FileFetcherServer.js#L109-L164
[t-path]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/Plugin/FileOperator/FileOperator.js#L85-L114
[t-agent]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/routes/admin/agents.js#L1-L115
[t-auth]: https://github.com/lioensky/VCPToolBox/blob/0c919a3b16f10003f7bea4238a3863e1200cf690/server.js#L857-L884
