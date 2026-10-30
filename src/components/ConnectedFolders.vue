<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import AppIcon from "./AppIcon.vue";
import {
  connectedFiles,
  folderJoin,
  mobileFileManifest,
} from "../files/connected";
import type {
  ConnectedFolder,
  FolderEntry,
  FolderBackup,
  FolderAccess,
} from "../files/connected";
import { useConfirmationStore } from "../stores/confirmation";
import { useSettingsStore } from "../stores/settings";
import { useFileNodeStore } from "../stores/fileNode";
import { isTauri } from "../protocol/http";
import { addFile, mimeFor } from "../files/library";
import { base64 } from "../files/bytes";
const confirmation = useConfirmationStore(),
  settings = useSettingsStore(),
  node = useFileNodeStore();
const roots = ref<ConnectedFolder[]>([]),
  folder = ref<ConnectedFolder | null>(null),
  directory = ref(""),
  items = ref<FolderEntry[]>([]),
  selected = ref<FolderEntry | null>(null),
  backups = ref<FolderBackup[]>([]);
const busy = ref(false),
  error = ref(""),
  status = ref(""),
  text = ref(""),
  original = ref(""),
  showBackups = ref(false),
  truncated = ref(false),
  showNode = ref(false),
  create = ref(false),
  createType = ref("file"),
  newName = ref(""),
  newText = ref(""),
  operation = ref("RenameFile"),
  destination = ref("");
const dirty = computed(
  () => selected.value?.text !== undefined && text.value !== original.value,
);
const image = computed(() =>
  selected.value?.base64 &&
  /^image\/(png|jpeg|gif|webp)$/.test(mimeFor(selected.value.name))
    ? `data:${mimeFor(selected.value.name)};base64,${selected.value.base64}`
    : "",
);
const toolName = computed(() =>
  settings.settings.fileNodeId
    ? mobileFileManifest(settings.settings.fileNodeId).name
    : "",
);
const nodeUrl = ref(settings.settings.fileNodeUrl),
  nodeKey = ref(settings.settings.fileNodeKey),
  nodeName = ref(settings.settings.fileNodeName);
const labels: Record<string, string> = {
  WriteFile: "保存",
  AppendFile: "追加",
  EditFile: "替换",
  MoveFile: "移动",
  RenameFile: "改名",
  DeleteFile: "删除",
  RestoreBackup: "恢复前的备份",
};
async function task(work: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  status.value = "";
  try {
    await work();
  } catch (e) {
    error.value = e instanceof Error ? e.message : String(e);
  } finally {
    busy.value = false;
  }
}
async function load() {
  if (!isTauri()) return;
  roots.value = await connectedFiles.folders();
  if (folder.value)
    folder.value = roots.value.find((f) => f.id === folder.value!.id) ?? null;
}
async function browse(path = directory.value) {
  if (!folder.value) return;
  const result = await connectedFiles.list(folder.value.id, path);
  items.value = result.items.sort(
    (a, b) =>
      Number(b.type === "directory") - Number(a.type === "directory") ||
      a.name.localeCompare(b.name),
  );
  directory.value = path;
  truncated.value = result.truncated;
  selected.value = null;
}
async function discard() {
  return (
    !dirty.value ||
    (await confirmation.ask({
      title: "离开编辑",
      body: "尚未保存的编辑会被丢弃，原文件未改动。",
      label: "离开",
    }))
  );
}
async function enter(root: ConnectedFolder) {
  if (!(await discard())) return;
  await task(async () => {
    folder.value = root;
    directory.value = "";
    showBackups.value = false;
    create.value = false;
    await browse("");
  });
}
async function back() {
  if (!(await discard())) return;
  error.value = "";
  status.value = "";
  if (selected.value) {
    selected.value = null;
    return;
  }
  if (showBackups.value) {
    showBackups.value = false;
    return;
  }
  if (create.value) {
    create.value = false;
    return;
  }
  if (directory.value) {
    await task(() => browse(directory.value.split("/").slice(0, -1).join("/")));
    return;
  }
  folder.value = null;
}
async function connect() {
  await task(async () => {
    const result = await connectedFiles.connect();
    if ("canceled" in result) return;
    await load();
    folder.value = result;
    directory.value = "";
    await browse("");
    status.value = "已连接；直接修改原文件前会自动保存备份";
  });
}
async function open(file: FolderEntry) {
  if (file.type === "symlink") return;
  if (file.type === "directory") {
    await task(() => browse(file.path));
    return;
  }
  await task(async () => {
    if (!folder.value) return;
    selected.value = await connectedFiles.read(folder.value.id, file.path);
    text.value = selected.value.text ?? "";
    original.value = text.value;
    destination.value = file.path;
    operation.value = "RenameFile";
  });
}
async function inspectFolder(file: FolderEntry) {
  await task(async () => {
    if (!folder.value) return;
    selected.value = await connectedFiles.info(folder.value.id, file.path);
    destination.value = file.path;
    operation.value = "RenameFile";
  });
}
async function save() {
  if (!folder.value || !selected.value || !dirty.value) return;
  const f = folder.value,
    file = selected.value;
  await task(async () => {
    const result = await connectedFiles.write(
      f.id,
      file.path,
      text.value,
      file.version,
    );
    selected.value = {
      ...file,
      version: result.version,
      text: text.value,
      base64: base64(new TextEncoder().encode(text.value)),
      size: new TextEncoder().encode(text.value).length,
    };
    original.value = text.value;
    status.value = "已原地保存，修改前的内容已备份";
  });
}
async function move() {
  if (!folder.value || !selected.value) return;
  const f = folder.value,
    file = selected.value,
    target = destination.value,
    command = operation.value;
  if (
    !(await confirmation.ask({
      title: "确认文件操作",
      body: `${command === "CopyFile" ? "复制" : command === "MoveFile" ? "移动" : "改名"}\n${file.path}\n→ ${target}\n不覆盖已有目标；改名和移动前会备份原内容。`,
      label: "确认执行",
    }))
  )
    return;
  await task(async () => {
    await connectedFiles.execute(f.id, {
      command,
      sourcePath: file.path,
      destinationPath: target,
      expectedVersion: file.version,
    });
    await browse();
    status.value = "操作完成；原有目标不会被覆盖";
  });
}
async function remove() {
  if (!folder.value || !selected.value) return;
  const f = folder.value,
    file = selected.value;
  if (
    !(await confirmation.ask({
      title: "移入备份回收站",
      body: `${file.path}\n先保存完整备份，再从原位置移除。可在本页“备份与恢复”中恢复。`,
      label: "移入备份回收站",
      danger: true,
    }))
  )
    return;
  await task(async () => {
    await connectedFiles.execute(f.id, {
      command: "DeleteFile",
      filePath: file.path,
      expectedVersion: file.version,
    });
    await browse();
    status.value = "已移入备份回收站";
  });
}
async function backupList() {
  if (!folder.value || !(await discard())) return;
  await task(async () => {
    backups.value = await connectedFiles.backups(folder.value!.id);
    showBackups.value = true;
    selected.value = null;
    create.value = false;
  });
}
async function restore(b: FolderBackup) {
  if (!folder.value) return;
  const f = folder.value;
  if (
    !(await confirmation.ask({
      title: "恢复备份",
      body: `恢复到 ${b.path}\n原位置若有文件，会先备份当前内容。改名或移动产生的新副本不会被删除；已有文件夹不会被覆盖。`,
      label: "恢复备份",
    }))
  )
    return;
  await task(async () => {
    await connectedFiles.restore(f.id, b);
    backups.value = await connectedFiles.backups(f.id);
    status.value = "已恢复到原路径，当前内容也已保留备份";
  });
}
async function grant(root: ConnectedFolder, event: Event) {
  const select = event.target as HTMLSelectElement,
    next = select.value as FolderAccess;
  select.value = root.agentAccess;
  if (
    next !== "off" &&
    !(await confirmation.ask({
      title: "授权移动文件工具",
      body: `允许连接的 VCP 服务中的 Agent ${next === "write" ? "读写" : "读取"}“${root.name}”及其中的文件？修改前仍会备份，可随时关闭权限。`,
      label: "允许",
    }))
  )
    return;
  await task(async () => {
    await connectedFiles.grant(root.id, next);
    await load();
    status.value =
      next === "off"
        ? "已关闭此文件夹的 Agent 权限"
        : "已更新此文件夹的 Agent 权限";
  });
}
async function disconnect(root: ConnectedFolder) {
  if (
    !(await confirmation.ask({
      title: "断开文件夹",
      body: `断开“${root.name}”？原文件和已有备份保留，Agent 立即失去访问权限。重新连接同一目录可继续恢复备份。`,
      label: "断开连接",
    }))
  )
    return;
  await task(async () => {
    await connectedFiles.disconnect(root.id);
    folder.value = null;
    selected.value = null;
    await load();
    status.value = "已断开，原文件与备份保留";
  });
}
async function upload(event: Event) {
  const input = event.target as HTMLInputElement,
    file = input.files?.[0];
  input.value = "";
  if (!file || !folder.value) return;
  const f = folder.value;
  await task(async () => {
    if (file.size > 20_000_000) throw new Error("单个文件上限20MB");
    await connectedFiles.write(
      f.id,
      folderJoin(directory.value, file.name),
      base64(new Uint8Array(await file.arrayBuffer())),
      undefined,
      "base64",
    );
    await browse();
    status.value = "已保存到连接的文件夹；未覆盖同名文件";
  });
}
async function createItem() {
  if (!folder.value) return;
  await task(async () => {
    const path = folderJoin(directory.value, newName.value);
    if (createType.value === "folder")
      await connectedFiles.folder(folder.value!.id, path);
    else await connectedFiles.write(folder.value!.id, path, newText.value);
    create.value = false;
    await browse();
    status.value = "已创建，未覆盖已有项目";
  });
}
async function keepCopy() {
  if (!selected.value?.base64) return;
  const f = selected.value;
  await task(async () => {
    await addFile(
      f.name,
      Uint8Array.from(atob(f.base64!), (c) => c.charCodeAt(0)),
      mimeFor(f.name),
      "连接文件夹副本",
    );
    status.value = "副本已加入本机附件，原文件未改动";
  });
}
async function enableNode(event: Event) {
  const input = event.target as HTMLInputElement,
    on = input.checked;
  input.checked = settings.settings.fileNodeEnabled;
  if (
    on &&
    (!settings.settings.fileNodeUrl.trim() ||
      !settings.settings.fileNodeKey.trim())
  ) {
    error.value = "先填写 VCP 地址和分布式 Key";
    return;
  }
  await task(async () => {
    await settings.patch({
      fileNodeId: settings.settings.fileNodeId || crypto.randomUUID(),
      fileNodeEnabled: on,
    });
  });
}
onMounted(() => void task(load));
</script>
<template>
  <div
    class="connected-folders"
    @keydown.meta.s.prevent="save"
    @keydown.ctrl.s.prevent="save"
  >
    <p v-if="busy" class="hint" role="status">正在处理…</p>
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
    <p v-if="status" class="connected-status" role="status">{{ status }}</p>
    <p v-if="!isTauri()" class="hint">
      请使用 Mac 或 iOS App 连接系统文件夹；网页仍可使用本机附件和服务器文件。
    </p>
    <template v-if="folder">
      <div class="folder-toolbar">
        <button class="ghost" type="button" :disabled="busy" @click="back">
          <AppIcon name="back" :size="16" />{{
            selected || create || showBackups
              ? "返回文件夹"
              : directory
                ? "上一级"
                : "所有连接"
          }}
        </button><strong>{{ folder.name }}</strong>
      </div>
      <p v-if="directory && !selected && !showBackups" class="connected-path">
        {{ directory }}
      </p>
      <template v-if="showBackups">
        <h2>备份与恢复</h2>
        <p class="hint">
          备份保存在 App 内，不上传。恢复到原路径；不会清理移动或改名后的副本。
        </p>
        <div v-if="backups.length" class="settings-group">
          <div v-for="b in backups" :key="b.id" class="backup-row">
            <div>
              <strong>{{ b.path }}</strong><small>{{ labels[b.operation] || b.operation }} ·
                {{ new Date(b.createdAt).toLocaleString("zh-CN") }}</small>
            </div>
            <button
              class="ghost"
              type="button"
              :disabled="busy"
              :aria-label="`恢复 ${b.path}`"
              @click="restore(b)"
            >
              恢复
            </button>
          </div>
        </div>
        <p v-else class="hint">还没有修改备份。</p>
      </template>
      <template v-else-if="selected">
        <h2 class="connected-path">{{ selected.name }}</h2>
        <p class="hint">
          {{
            selected.type === "directory"
              ? "文件夹"
              : `${(selected.size / 1024).toFixed(1)} KB`
          }}
          · {{ selected.path }}
        </p>
        <template v-if="selected.text !== undefined">
          <label class="field">文件内容<textarea
            v-model="text"
            aria-label="编辑连接文件"
            rows="14"
            spellcheck="false"
            :disabled="busy"
          /></label><button
            class="primary"
            type="button"
            :disabled="busy || !dirty"
            @click="save"
          >
            {{ dirty ? "保存原文件（先备份）" : "已保存" }}
          </button>
        </template>
        <img
          v-else-if="image"
          :src="image"
          class="connected-image"
          alt="连接文件预览"
        />
        <p v-else-if="selected.type === 'file'" class="hint">
          此类型保留原始字节，可复制到本机附件后导出。
        </p>
        <button
          v-if="selected.type === 'file'"
          class="ghost"
          type="button"
          :disabled="busy"
          @click="keepCopy"
        >
          复制到本机附件
        </button>
        <form class="card form-stack" @submit.prevent="move">
          <label class="field">文件操作<select v-model="operation" :disabled="busy || dirty">
            <option value="RenameFile">改名</option>
            <option value="MoveFile">移动</option>
            <option value="CopyFile">复制</option>
          </select></label><label class="field">目标相对路径<input
            v-model="destination"
            aria-label="连接文件目标路径"
            :disabled="busy || dirty"
            placeholder="子目录/文件名.txt"
            autocapitalize="none"
          /></label>
          <p v-if="dirty" class="hint">
            先保存或放弃当前编辑，再执行文件操作。
          </p>
          <button class="ghost" type="submit" :disabled="busy || dirty">
            确认文件操作
          </button>
        </form>
        <div class="folder-actions">
          <button
            class="ghost"
            type="button"
            :disabled="busy"
            @click="backupList"
          >
            备份与恢复
          </button><button
            class="text-button connected-danger"
            type="button"
            :disabled="busy || dirty"
            @click="remove"
          >
            移入备份回收站
          </button>
        </div>
      </template>
      <form
        v-else-if="create"
        class="card form-stack"
        @submit.prevent="createItem"
      >
        <label class="field">类型<select v-model="createType">
          <option value="file">文本文件</option>
          <option value="folder">文件夹</option>
        </select></label><label class="field">名称<input
          v-model="newName"
          required
          aria-label="连接文件新名称"
          placeholder="笔记.md"
        /></label><label v-if="createType === 'file'" class="field">内容<textarea
          v-model="newText"
          rows="10"
          aria-label="连接文件新内容"
        /></label><button class="primary" type="submit" :disabled="busy">
          创建（不覆盖同名项目）
        </button>
      </form>
      <template v-else>
        <div class="folder-actions">
          <button
            class="ghost"
            type="button"
            :disabled="busy"
            @click="
              create = true;
              newName = '';
              newText = '';
            "
          >
            新建
          </button><label class="ghost file-action">添加文件<input
            class="sr-only"
            type="file"
            aria-label="添加到连接文件夹"
            :disabled="busy"
            @change="upload"
          /></label><button
            class="ghost"
            type="button"
            :disabled="busy"
            @click="backupList"
          >
            备份与恢复
          </button><button
            class="icon-button"
            type="button"
            aria-label="刷新连接文件夹"
            :disabled="busy"
            @click="task(() => browse())"
          >
            <AppIcon name="sync" />
          </button>
        </div>
        <div v-if="items.length" class="settings-group">
          <div v-for="file in items" :key="file.path" class="connected-entry">
            <button
              class="settings-row"
              type="button"
              :disabled="busy || file.type === 'symlink'"
              @click="open(file)"
            >
              <span class="setting-icon"><AppIcon
                :name="
                  file.type === 'directory' ? 'folder' : 'notes'
                "
              /></span><span><strong>{{ file.name }}</strong><small>{{
                file.type === "directory"
                  ? "文件夹"
                  : file.type === "symlink"
                    ? "符号链接（不访问）"
                    : `${(file.size / 1024).toFixed(1)} KB`
              }}</small></span><AppIcon name="chevron" :size="16" />
            </button><button
              v-if="file.type === 'directory'"
              class="icon-button"
              type="button"
              :aria-label="`管理连接文件夹 ${file.name}`"
              :disabled="busy"
              @click="inspectFolder(file)"
            >
              <AppIcon name="more" />
            </button>
          </div>
        </div>
        <div v-else class="empty compact">
          <AppIcon name="folder" :size="32" />
          <h2>这个文件夹是空的</h2>
          <p>新建文件，或添加已有文件。</p>
        </div>
        <p v-if="truncated" class="hint">
          仅显示前2000项；请进入更具体的子目录。
        </p>
      </template>
    </template>
    <template v-else>
      <div class="card form-stack">
        <h2>连接你的工作文件夹</h2>
        <p class="hint">
          从系统文件选择器授权一个目录，直接读写原文件；每次修改前自动备份。断开不会删除原文件或备份。
        </p>
        <button
          class="primary"
          type="button"
          :disabled="busy || !isTauri()"
          @click="connect"
        >
          <AppIcon name="folder" :size="18" />连接文件夹
        </button>
      </div>
      <div v-for="root in roots" :key="root.id" class="card form-stack">
        <button
          class="settings-row root-open"
          type="button"
          :disabled="busy"
          @click="enter(root)"
        >
          <span class="setting-icon"><AppIcon name="folder" /></span><strong>{{ root.name }}</strong><AppIcon name="chevron" :size="18" />
        </button><label class="field">Agent 权限<select
          :value="root.agentAccess"
          :aria-label="`${root.name} Agent权限`"
          :disabled="busy"
          @change="grant(root, $event)"
        >
          <option value="off">不允许 Agent 访问</option>
          <option value="read">允许 Agent 读取</option>
          <option value="write">允许 Agent 读写（修改前备份）</option>
        </select></label>
        <div class="folder-actions">
          <button
            class="text-button"
            type="button"
            :disabled="busy"
            @click="enter(root)"
          >
            打开文件夹
          </button><button
            class="text-button"
            type="button"
            :disabled="busy"
            @click="disconnect(root)"
          >
            断开连接
          </button>
        </div>
      </div>
      <button class="ghost" type="button" @click="showNode = !showNode">
        移动版 FileOperator · {{ node.status }}
      </button>
      <div v-if="showNode" class="card form-stack">
        <h2>让 VCP 调用此设备</h2>
        <p class="hint">
          只有上面明确授权的文件夹可被读取或修改。工具只在 App
          前台连接；修改前的备份不会上传。
        </p>
        <label class="field">VCP 地址<input
          v-model="nodeUrl"
          type="url"
          placeholder="https://你的VCP服务器:6005"
          autocapitalize="none"
          @change="settings.patch({ fileNodeUrl: nodeUrl })"
        /></label><label class="field">VCP 分布式 Key<input
          v-model="nodeKey"
          type="password"
          autocomplete="off"
          @change="settings.patch({ fileNodeKey: nodeKey })"
        /></label><label class="field">设备名称<input
          v-model="nodeName"
          @change="settings.patch({ fileNodeName: nodeName })"
        /></label><label class="check"><input
          type="checkbox"
          :checked="settings.settings.fileNodeEnabled"
          :disabled="busy || !isTauri()"
          @change="enableNode"
        />启用移动文件工具</label>
        <p role="status">{{ node.status }}</p>
        <p v-if="toolName" class="connected-path">工具名：{{ toolName }}</p>
        <p class="hint">
          先用 ListAllowedDirectories 获取
          folderId。修改已有文件须先读取当前版本；每台设备使用独立工具名，不覆盖电脑的
          FileOperator。
        </p>
      </div>
    </template>
  </div>
</template>
<style scoped>
.connected-folders {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.connected-folders h2 {
  font-size: 18px;
  margin: 0;
}
.folder-toolbar,
.folder-actions {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.folder-toolbar > strong {
  flex: 1;
  overflow-wrap: anywhere;
}
.folder-actions > .ghost {
  font-size: 13px;
  min-height: 42px;
}
.connected-path {
  overflow-wrap: anywhere;
  font-size: 13px;
  line-height: 1.6;
}
.connected-status {
  padding: 12px;
  background: var(--glass);
  border-radius: 12px;
  color: var(--accent);
  overflow-wrap: anywhere;
}
.connected-entry {
  display: flex;
  align-items: center;
}
.connected-entry > .settings-row {
  flex: 1;
  min-width: 0;
}
.connected-entry > .icon-button {
  flex-shrink: 0;
  margin-right: 8px;
}
.connected-image {
  max-width: 100%;
  max-height: 42vh;
  object-fit: contain;
}
.backup-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 14px;
  border-bottom: 1px solid var(--line);
}
.backup-row > div {
  flex: 1;
  min-width: 0;
}
.backup-row strong {
  display: block;
  font-size: 14px;
  overflow-wrap: anywhere;
}
.backup-row small {
  display: block;
  font-size: 12px;
  color: var(--muted);
}
.backup-row .ghost {
  min-height: 40px;
  padding: 8px 12px;
}
.root-open {
  padding: 0;
  gap: 12px;
}
.root-open > strong {
  flex: 1;
  text-align: left;
  overflow-wrap: anywhere;
}
.connected-danger {
  color: var(--danger);
}
textarea {
  font-family: var(--mono);
  font-size: 15px;
  line-height: 1.65;
}
</style>
