# VChat-iOS × VCP 定位隐私基线与轻量化全年足迹 / AI 行程感知架构（v4.0）

> **文档状态**：活文档（Living Spec · **v4.0 拍板定稿**，取代原 v3.3 侵入主干方案）· 最后更新 `2026-11-23`
> **协同文档**：
> - iOS 端总契约：`/Users/zhaoyuanhao/Documents/vchat ios/docs/LOCATION_ARCHITECTURE_V3.md`（本文档）
> - 37 端同源契约：`/home/debian/VCPToolBox/docs/LOCATION_TRACKING_V3_CONTRACT.md`
> - 37 主干台账：`/home/debian/VCPToolBox/docs/LOCAL_ADAPTATIONS.md`
>
> **架构总铁律（v4.0 转向核心）**：
> 1. **`VCPToolBox` 主干 0 行改动**：不修改 `server.js`、不向 VCP 主干塞轨迹库或重型三权管理后台；所有社区 VChat-iOS 用户连接 100% 原版 VCPToolBox 即可开箱使用全部端侧定位与本地足迹功能。
> 2. **隐私与用途隔离**：聊天定位（发消息 `tray`）按 Agent 白名单与共享地点 ACL 严格过滤；云端足迹同步为默认关闭的可选开关，支持标准通用协议。
> 3. **给地图看几何，给 AI 看语义**：绝不向大模型倾倒裸经纬度数组，AI 始终只读取聚合后的结构化移动状态、每日行程卡片与周期统计。

---

## 0. 里程碑进度总览

| 阶段 | 范围 | 当前状态 | 验收基线 |
|---|---|---|---|
| **阶段一 · iOS 止血修复** | 修复 3×P1 + 2×P2 + 后台空转；删除轨 B WS 坐标推送 | ✅ **已完成并自测通过** | `plutil -lint Configuration/Info.plist` OK；`swift test` **21/21 passed** |
| **阶段一 · 37 服务端清理** | 移除 `DeviceLocationEnricher` 设备级 `entry.savedPlaces` 跨 Agent 回退；放宽 `reduced ≤ 50000m`；`full -> reduced` 淘汰旧精确缓存；删除旧 `location_state.json` | ✅ **已完成并线上激活** | `node --check` OK；`deviceLocationEnricher` **5/5** + 关联 **16/16**；`pm2 vcp-main`（pid=2188070）已重启激活 |
| **阶段二 · v4.0 三件套** | ① iOS 本地全年足迹与滑窗语义底座；② 独立极简 Node+SQLite 足迹与可视化小服务；③ 37 纯独立只读插件 `Plugin/LocationFootprint/` | 📝 **v4.0 方向已拍板（待分模块开工程施工）** | 按第 6 节模块单测 + 真机能耗/轨迹实测验收 |

---

## 1. 阶段一基线（已双端闭环，严禁回归）

### 1.1 iOS 端已落地基线（分支 `feat/ios-location-context`）
1. **彻底移除聊天定位的 WS 广播**：仅保留逐请求 `LocationRequestContext.tray()`；群聊 `.include` 严格受白名单与群成员过滤；增删常用地点零网络广播。
2. **授权代次与降精度隔离**：`Grant(status, precise)` + `generation` + 独立 `sampler` 实例拦截迟到回调；缓存键 `vchat.location.foreground.v3`；`.fullAccuracy ↔ .reducedAccuracy` 双向切换立刻清空缓存并作废在途等待者；发送 HTTP body 前最后一步 `syncGrant()` 复核。
3. **单次取点与持续监听解耦**：普通单次取点仅申请 `WhenInUse`，绝不静默升级 `Always`。
4. **保存当前位置严格门禁**：`captureFreshPoint()` 仅实测 `precise && 0...10s && <= 20m` 自动写入，其余弹窗确认。
5. **滤波统一与退后台零空转**：`reduced` 不套精确 `<= 1000m` 上限；`setForeground(false)` 立即释放聊天定位需求。

### 1.2 37 服务端已落地基线（`vcp-main` 已重启生效）
- `DeviceLocationEnricher.js`：永久移除设备级 `entry.savedPlaces` 写入/落盘/跨 Agent 回退；新增 `_invalidatePreciseCache` 与 `invalidatedFullBeforeMs`，`full -> reduced` 淘汰旧精确缓存并阻断 WS 复活；已清空旧 `state/location_state.json`。
- `geoStateCore.js` & `WebSocketServer.js`：`reduced` 上限放宽至 `50000m`（`full` 仍 `<= 2000m`），WS 入站剥离 `saved_places`。

---

## 2. 阶段二（v4.0）：三大真实需求与极简三件套架构

### 2.1 三大真实需求对应落点

| 编号 | 真实需求 | 核心承担模块 | 对 VCPToolBox 主干的影响 |
|---|---|---|---|
| **需求 1** | 在外步行/乘车/到店时，随时打开 VChat 跟白名单 AI 聊天，AI 立刻知道“刚从哪来、步行还是坐车、停了多久、是不是在回家路上” | **模块 A · iOS 本地底座**（端侧滑窗计算，直接写入现有 `tray`） | **0 改动**（原版 VCPToolBox 开箱即用；37 装了 `DeviceLocationEnricher` 自动补街道与 50m POI） |
| **需求 2** | 压根没跟 AI 聊天时，AI 通过 `AgentHeartbeat` / 主动消息感知“主人刚出门 / 刚到家 / 正在外面移动” | **模块 B · 独立极简 Node 足迹服务** + **模块 C · 37 纯插件 `LocationFootprint`**（提供 `{{UserLiveMovement}}` 占位符） | **0 改动**（纯 `Plugin/` 可选目录，删目录即无痕） |
| **需求 3** | 一整年移动轨迹可视化展示（热力图/分段路线/年度统计）+ 让 AI 能回顾和总结全年行踪 | **模块 A**（本机 MapKit 回看 + 导出）+ **模块 B**（全年 SQLite 归档 + 同源静态地图页）+ **模块 C**（只读语义查询工具 & 日记联动） | **0 改动** |

### 2.2 端到端极简拓扑

```text
┌──────────────────────────────────────────────────────────────────────┐
│ 模块 A：VChat-iOS（所有人开箱即用，默认零云端依赖）                    │
│  · LocationAcquisitionCoordinator 统一协调聊天定位与本地足迹          │
│  · 本地独立 GRDB：LocationTracks/location-tracks.sqlite (~10MB/年)    │
│  ├─▶ [需求 1] 发消息时用近 30min 本地滑窗算出移动/停留/回家 → 标准 tray │
│  ├─▶ [需求 3 本机] App 内 MapKit 按天/月/年看足迹 + 导出 GeoJSON/摘要 │
│  └─▶ [可选同步，默认关] 状态跃迁/移动每 3–5 分钟批量 HTTPS 推送       │
│        （兼容 OwnTracks HTTP JSON / 精简批量 JSON，可连任意独立服务） │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ HTTPS + 独立写 Token（仅个人开启）
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 模块 B：独立极简 Node+SQLite 足迹小服务（~200-300 行，独立进程/端口） │
│  · 部署于 37 或 Debian 家服，零 Docker，复用 Node 22 + better-sqlite3 │
│  · 写入：POST /ingest/owntracks & POST /ingest/batch（幂等 + 水位）   │
│  · 可视化：同源轻量地图页（MapLibre/Leaflet，分段路线/热力图/年统计） │
│  · 只读语义 API：/api/live-state、/api/timeline、/api/summary         │
└──────────────────────────────────┬───────────────────────────────────┘
                                   │ 本地/内网只读 Token
                                   ▼
┌──────────────────────────────────────────────────────────────────────┐
│ 模块 C：VCPToolBox/Plugin/LocationFootprint/（纯独立可选插件）        │
│  · hybridservice + direct，0 改 server.js                             │
│  ├─▶ 静态占位符 {{UserLiveMovement}} → 供 AgentHeartbeat 主动感知     │
│  └─▶ 只读工具 GetDailyTimeline / GetPeriodSummary → 给 AI 看全年语义  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. 模块 A：VChat-iOS 本地足迹与行程语义底座（核心工程规范）

保留此前 Codex 审查沉淀的 **iOS 底层硬核安全与省电实践**，剥离与“5秒远程找手机追踪器”相关的多余复杂度：

### 3.1 采集协调与双省电档位
- **统一协调者 `LocationAcquisitionCoordinator`**：
  - 聊天定位（轨 B）与本地足迹（轨 A）**仅可共享当次原始传感器读数**，严禁共享数据库/历史缓存，严禁轨 B 借用轨 A 的 `Always` 权限；轨 B 退后台仅释放轨 B 槽位，绝不误停正在运行的轨 A。
- **独立总开关 `footprintTracking.enabled`（默认关闭）** + 双省电档位：
  - **省电档（推荐日常，近零耗电）**：`CLVisit`（到店/离家系统级驻留事件）+ `SignificantLocationChanges`（基站级大位移），适合主要关心“去过哪/停留多久/离家到家”。
  - **连续档（街道级轨迹）**：iOS 17 `CLLocationUpdate.liveUpdates(.default)` + `CLBackgroundActivitySession`，依靠系统原生静止暂停/移动恢复，**不引入 `CMMotionActivity`**，不以 70m 传统围栏作为唯一触发器。
- **全批滤波与轻量抽稀（控制全年体积 ~6–15 MB）**：
  - 误差圈漂移抑制（`distance > max(12m, 0.7 * horizontalAccuracy)`），保留有效拐点（相邻点垂直偏差阈值 ~5–8m），精确模式过滤野点，大致精度仅以粗点记录不画道路折线。
- **缺口切段铁律**：
  - 相邻有效实测点间隔 **`> 120s`**、系统暂停恢复、冷启恢复、精度在 `full ↔ reduced` 切换、关闭后重开、或磁盘满恢复写入时，强制切新 `segment_id`；地图绝不跨段拉直线。仅网络延迟/离线不切段。

### 3.2 非 UI 后台恢复、目录优先保护与持久 Keychain（沿用 Codex 终审铁律）
- **`Configuration/Info.plist`**：施工开启后台足迹时，配置 `UIBackgroundModes = ["audio", "location"]` 与清晰的 `NSLocationAlwaysAndWhenInUseUsageDescription`。
- **`VChatApp.swift` 接入 `AppDelegate`**：后台恢复必须同时满足**三条件合取（AND）**：
  1. 持久化开关 `footprintTracking.enabled == true`；
  2. 当前系统授权严格为 `.authorizedAlways`（仅 `WhenInUse` 只在前台记点，绝不进入后台恢复）；
  3. 此前在前台已建立并记录可恢复的后台会话状态。
  - `launchOptions?[.location]` 仅作线索，绝不绕过三条件。
- **锁屏恢复实探法（禁用 `isProtectedDataAvailable` 误判）**：
  - **先建目录** `LocationTracks/` 并设置 `FileProtectionType.completeUntilFirstUserAuthentication` 与 `isExcludedFromBackup = true`，再打开独立 GRDB `location-tracks.sqlite`；
  - 后台启动直接无交互尝试打开 GRDB 与读取持久 Keychain（强制持久化，禁用 `CredentialVault` 内存 `.session`）；仅遇到不可访问错误（重启尚未首解锁）才等待 `protectedDataDidBecomeAvailableNotification`，期间**绝不新建身份或覆盖已有队列**。

### 3.3 需求 1 实现：端侧近 30 分钟滑窗语义直塞标准 `tray`
- 发送聊天消息时，若目标 Agent 在聊天位置白名单内且处于精确授权（`precise == true`）：
  - 在客户端本地读取最近 15–30 分钟（最多 15 点）滑窗 + 经该 Agent ACL 过滤后的 `sharedPlaces`，现场计算并写入 `device_location` JSON：
    - `motion_state`（`stationary` / `walking` / `vehicle` / `dwelling`）、`speed_mps`、`course_deg`、`dwelling`、`dwell_sec`；
    - `heading_to_home`（`at_home` / `leaving` / `returning` / `passing` / `stationary`）与 `distance_to_home_m`（**仅当“家”在该 Agent 的 `sharedPlaces` 白名单内才计算，严禁越权泄漏**）；
    - 可选简短 `recent_movement`（如最近 15 分钟累计位移米数与起点时间）。
  - 若目标 Agent 不在白名单、用户选 `.omit`、或降级为 `reduced` 大致定位，**严禁**从本地足迹库回填任何精确点或语义。

### 3.4 可选云端标准外推（默认关闭，不绑定 VCP）
- 用户主动填写「外部足迹服务 URL（强制 HTTPS）+ 写入 Token」并开启同步后：
  - 使用短超时普通 `URLSession`（8–10s，gzip，串行并发=1），失败留在本地队列按指数退避补传（不影响本地全年回看）；
  - **触发节奏（省电优先，不做 5 秒追踪）**：
    - 状态跃迁（离家 / 到家 / 静止转移动 / 停留满 5 分钟）立即触发一次上传；
    - 持续移动态每 **3–5 分钟** 或积攒 **15 点** 合并批量上传；
    - 静止休眠态 **0 心跳、0 唤醒**；
  - **数据格式**：优先支持极简批量 JSON（含 `point_id`、`segment_id`、`measured_at_ms`、`lat`、`lng`、`accuracy_m`、`speed_mps`、`course_deg`、`accuracy_auth`、`motion_state`、`transition_event`），并可选兼容标准 **OwnTracks HTTP JSON**（单点 `_type: "location"`），让社区用户也能直连自己的 Home Assistant / Dawarich。
  - **关闭与降精度**：关闭外推立即停止上传未同步队列；精确→大致降级丢弃未外推的旧精确待发项，并发送一次无坐标状态更新通知云端更新当前状态。

---

## 4. 模块 B：独立极简 Node+SQLite 足迹与可视化小服务（~200–300 行）

独立部署于 37 服务器（独立 PM2 进程，例如 `vcp-footprint`，监听本机回环端口由反代暴露 HTTPS）或 Debian 家服，**与 `VCPToolBox` 进程和代码完全物理隔离**。

### 4.1 极简 SQLite Schema（`footprint.sqlite`，WAL 模式）
仅需 3 张核心表 + 1 张删除水位元数据表：
1. `points`：`point_id (PK)`, `device_id`, `segment_id`, `measured_at_ms`, `lat`, `lng`, `accuracy_m`, `speed_mps`, `course_deg`, `accuracy_auth`, `motion_state`, `transition_event`, `received_at_ms`；索引 `(device_id, measured_at_ms)`。
2. `geo_cache`：网格化逆地理缓存（`grid_key (PK)` ~50m 精度，`street`, `area`, `poi_name`, `resolved_at_ms`），只对“停留点/状态跃迁点”做异步 Nominatim/Photon 逆地理，避免高频打爆上游。
3. `device_meta`：`device_id (PK)`, `device_name`, `deleted_before_ms`, `clear_epoch`, `retention_days (default 365)`, `last_state_json`, `updated_at_ms`。

### 4.2 精简 HTTP 接口（3 组鉴权边界清晰）
- **写入面（`Authorization: Bearer <WRITE_TOKEN>`，HTTPS）**：
  - `POST /ingest/batch`：单批 `<= 200` 点、gzip 解压 `<= 1MB`；按 `point_id` 幂等去重；过滤 `measured_at_ms <= deleted_before_ms` 与 `clear_epoch` 过时旧批；过滤未来 `> +60s` 异常点；更新 `device_meta.last_state_json`（按 `measured_at_ms` 单调前推，支持无坐标降级/停用状态同步）；返回互斥 `acked_point_ids` 与 `rejected[]`。
  - `POST /ingest/owntracks`：兼容 OwnTracks 标准 HTTP 载荷，自动转换写入同一 `points` 表。
- **只读语义面（`Authorization: Bearer <READ_TOKEN>`，仅给 VCP 插件与受保护前端读）**：
  - `GET /api/live-state`：返回当前最新状态摘要（状态、`age_sec`、街道/区域、是否移动、距上次状态跃迁时长、精度级别；超 15 分钟自动标 `stale`），供需求 2 占位符使用。
  - `GET /api/tracks?from_ms=...&to_ms=...&simplify=...`：按 `segment_id` 返回分段折线（支持按年/月/日筛选与抽稀级别），供可视化网页渲染。
  - `GET /api/timeline?date=YYYY-MM-DD`：服务端将当天轨迹自动聚类为**停留段（Stay）+ 移动段（Trip）**，附带逆地理地点名、停留时长、交通方式、里程（供需求 3 给 AI 看）。
  - `GET /api/summary?from=YYYY-MM-DD&to=YYYY-MM-DD`：返回年度/月度总里程、活跃天数、交通方式占比、常去地点 Top 10、城市/区域分布（供需求 3 年度总结）。
- **管理面（基础登录密码 / `<ADMIN_TOKEN>` + 同源防 CSRF）**：
  - `DELETE /api/tracks?before_ms=...`：单事务删除历史并推进 `deleted_before_ms`（全量清空同步递增 `clear_epoch` + `T+60s` 水位），防止手机离线旧点回灌复活。
- **内置同源轻量静态地图页（`GET /`）**：
  - 单文件 HTML + Leaflet / MapLibre GL（含热力图插件）：支持日历选单日/选月份/看全年、严格按 `segment_id` 分段画线、停留点气泡、年度统计卡片、导出 GeoJSON 与一键清理历史。

---

## 5. 模块 C：37 端纯独立可选 VCP 插件 `Plugin/LocationFootprint/`

- **形态**：`hybridservice` + `nodejs` + `direct` 内存常驻插件，通过独立 `Plugin/LocationFootprint/config.env` 配置 `FOOTPRINT_API_URL` 与只读 `FOOTPRINT_READ_TOKEN`。**不修改 VCPToolBox 任何核心文件**，卸载只需删除插件目录。
- **能力 1（需求 2 · 不聊天时 AI 主动感知）**：
  - 后台定时（如每 60s）轻拉 `/api/live-state` 刷新静态占位符 `{{UserLiveMovement}}`（例如：`[主人实时行程] 2026-11-23 19:42（2分钟前实测）｜状态：步行（1.4 m/s），位于 Canning Circus, Nottingham（Derby Road），距上次出发已移动 14 分钟`）。
  - `AgentHeartbeat` 定时任务或白名单 Agent 提示词直接引用 `{{UserLiveMovement}}` 即可感知主人出门/到家/在外状态；若用户关闭了云端同步或超 TTL，占位符诚实显示「未开启或暂无近期动态」。
- **能力 2（需求 3 · 给 AI 看全年轨迹语义）**：
  - 提供两个只读工具指令：
    - `GetDailyTimeline(date)`：拉取 `/api/timeline`，返回脱水后的当日结构化时间轴（到访地点、停留时长、移动里程与方式）；
    - `GetPeriodSummary(from, to)`：拉取 `/api/summary`，返回月度/年度足迹报告（总里程、常去地 Top10、区域统计），可直接由 Agent 总结或沉淀到日记。
- **安全边界**：插件仅持有**只读 Token**，无权删除或篡改轨迹；`DeviceLocationEnricher`（聊天预处理器）依然与本插件完全解耦，不会替未获授权的 Agent 偷偷注入足迹。

---

## 6. 验收标准与施工顺序建议

### 6.1 推荐施工顺序（每一步独立可用，无长尾阻塞）
1. **第一站 · 模块 B（独立极简 Node+SQLite 足迹服务 + 单页年度地图）+ 模块 C（`Plugin/LocationFootprint/`）**：独立小仓库/目录施工，零触碰 `server.js`，跑通全部写入幂等/水位防回灌/聚类时间轴/年度统计/占位符单测。
2. **第二站 · 模块 A（VChat-iOS 本地全年足迹底座 + 滑窗语义 `tray` + App 内 MapKit 回看 + 可选外推开关）**：在 `vchat-ios` 工作区用 ProjectForge 施工，跑通自动化反例单测与实体 iPhone 省电/轨迹实测。

### 6.2 核心验收清单
- **零侵入核验**：`VCPToolBox` 核心主干（`server.js` 等）diff 为 `0`；未开启外推的 iOS 客户端连接原版 VCPToolBox 100% 正常工作。
- **隐私与隔离核验**：非白名单 Agent / `.omit` / `reduced` 绝不拿到本地足迹精确坐标或私有常用地点；关闭追踪或仅 `WhenInUse` 收到后台启动线索绝不恢复后台会话；锁屏实探正常恢复且重启未首解锁不重建身份。
- **数据完整性核验**：`>120s` 缺口必切段不拉直线；全量清空推进 `clear_epoch` + `T+60s` 后旧批不复活；10 万点模拟全年数据集查询与聚类响应 `< 200ms`。
- **真机量化基线（实体 iPhone 同机对照）**：省电档静置增量耗电 `≤ 0.5%/h`，连续档静置增量耗电 `≤ 1.5%/h`；步行绕 2 街角 + 2 分钟断网补传 `0` 重复点且拐角完整。

---

## 7. 文档更新日志（Changelog）

| 日期 | 版本 | 更新人 | 变更摘要 |
|---|---|---|---|
| `2026-11-23` | `v3.1–v3.3` | Kerr & Codex | 阶段一双端止血验收（iOS 21/21、37 5/5 + 16/16 且重启激活）；曾完成重型 Find-My 主干集成契约 v3.3 终签。 |
| `2026-11-23` | `v4.0` | Sijin & Kerr | **架构拍板减重转向**：确认不修改 `VCPToolBox` 主干，不逼迫其他 VChat-iOS 用户改后端；聚焦三大真实需求（聊天秒懂移动状态 + AI 心跳主动感知 + 一年可视化与 AI 回顾），定稿「iOS 本地全年足迹底座 + 独立极简 Node/SQLite 足迹小服务 + 37 纯独立只读插件 `LocationFootprint`」三件套，保留 v3.3 中全部 iOS 底层省电、后台恢复、数据保护与删清防回灌精华，归档并清理临时 `VCPToolBox-stage2` 镜像目录。 |