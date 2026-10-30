# 在原文件夹里工作

打开 **我 → 文件 → 连接文件夹**，从系统选择器选择工作目录。文件留在原位置；这里不是附件导入，也不是服务器磁盘。

## 连接、编辑与恢复

1. 点“连接文件夹”，选择允许 VCPChat 使用的目录。取消不会改变已有连接。
2. 打开目录，可浏览、创建目录或文件、导入文件、编辑 UTF-8 文本、预览图片，以及复制、移动、改名和删除。
3. “保存原文件”会先保存本机备份，再写回原文件。删除也先备份，可从该目录的“备份与恢复”找回。
4. 如果文件被外部程序或 Agent 改动，保存会提示 `CONFLICT`，保留你的编辑且不覆盖新内容。“重新读取”可载入最新内容；丢弃未保存编辑前会确认。
5. 断开连接不删除原文件和备份。重新通过系统选择器连接同一目录后，可继续使用已有备份，Agent 权限保持关闭。

恢复写回备份记录的原路径，覆盖文件前会再备份当前内容。已有文件夹不覆盖；移动或改名后的副本不会随恢复被删除。备份只在本机 App 数据目录内，不上传服务器，也不属于桌面会话同步。卸载 App 或清除它的数据会丢失这些备份。

## 让 VCP Agent 使用移动版 FileOperator

每个目录默认 **关闭** Agent 权限，可单独设置 **只读** 或 **读写**。启用需要确认，关闭即时生效。Agent 不能替自己授权、连接新目录或恢复备份。

展开“移动版 FileOperator”，填写 VCP 服务地址、原库分布式节点使用的 VCP Key 和设备显示名称，然后启用。地址填写服务根地址，不要把 Key 放进地址。不同于文件服务器 Key、聊天 API Key 或 MobileSync Token，这里使用分布式节点的 Key。

连接通过原库的 `/vcp-distributed-server/VCP_Key=…` WebSocket 协议注册：

```text
VCP Agent → execute_tool → 本设备 MobileFileOperator_<设备ID>
                             └─ folderId + 相对路径
                                └─ 原生授权 → 检查版本 → 备份 → 文件操作
           ← tool_result ← 实际结果或错误
```

工具名称在页面上显示，按设备生成并持久保存，不会抢占桌面 `FileOperator`。服务端需要把该工具的描述提供给使用它的 Agent。工具先调用 `ListAllowedDirectories` 取得 `folderId`，只会看到已授权的目录名称、ID 和权限，不会得到系统绝对路径或授权书签。

支持：`ListAllowedDirectories`、`ListDirectory`、`FileInfo`、`ReadFile`、`WriteFile`、`AppendFile`、`EditFile`、`CopyFile`、`MoveFile`、`RenameFile`、`DeleteFile`、`CreateDirectory`。

- 目录列表/新建目录：`directoryPath`；文件读写/删除：`filePath`；复制/移动/改名：`sourcePath` 和 `destinationPath`。路径均相对 `folderId`，根目录列表用空字符串。
- 修改已有文件或移动/删除项目前，先 `ReadFile` 或 `FileInfo`，把返回的 `version` 作为 `expectedVersion`。
- `WriteFile` 用 `content` 和 `encoding`（`utf8` 或 `base64`）；覆盖还须 `overwrite:true`。`AppendFile` 使用 `content`；`EditFile` 用 `oldText` 和替换内容 `content`，待替换文字必须恰好出现一次。
- 新文件、复制和移动目标同名时不覆盖。目录不允许递归隐式创建。
- 修改请求按服务端 `requestId` 保留回执，同一请求不会重复写入；相同 ID 的不同内容会报错。结果不确定时要求检查当前文件和备份，不自动重做。

节点只在 App 前台运行，回到前台自动重连。后台、App 退出或手机不可用时不接任务；不是 iOS 常驻执行服务。

## 范围与上限

- 仅访问系统选择器授权的目录，使用安全作用域书签保存连接，并通过 `NSFileCoordinator` 协调文件提供者访问。
- 拒绝绝对路径、`..` 越界、符号链接和 App 自身备份目录。文件提供者撤回授权或暂不可用时，需重新连接或检查提供者。
- 单文件读写最多 20 MB；Agent 单次读取最多 200 KB。单次目录备份最多 100 MB / 2000 项（其中单文件仍最多 20 MB），超出时不修改原项目。
- 列表最多展示 2000 项并显示截断提示。暂不支持跨授权根目录移动、任意命令执行、压缩解压或读写其他 App 私有目录。
- Mac 和 iOS 共用原生实现。iOS 接入“文件”App 的目录选择器；具体提供者是否允许选取、读写、离线访问，取决于系统和提供者。Mac 验收不替代 iPhone 真机验收。

## 开发检查

使用项目既有前端/Rust 检查；Mac 原生回归需另指定隔离产物目录：

```sh
pnpm check
cargo test --locked --lib --manifest-path src-tauri/Cargo.toml
bash scripts/test-connected-folders.sh /absolute/path/to/CodexArtifacts/folder-test
```

Swift 原生测试覆盖权限、原地写入、备份失败不写入、版本冲突、路径越界、目录移动/删除/恢复、重复请求、撤销连接、重连和授权持久化失败回滚。测试仅创建合成文件，不使用个人文档。
