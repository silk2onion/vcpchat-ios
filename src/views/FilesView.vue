<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { useConfirmationStore } from "../stores/confirmation";
import ConnectedFolders from "../components/ConnectedFolders.vue";
import AppIcon from "../components/AppIcon.vue";
import { useSettingsStore } from "../stores/settings";
import { getRepository } from "../storage";
import { FileClient, joinPath, normalizePath } from "../files/client";
import type { RemoteFile } from "../files/client";
import {
  addFile,
  collectHistoryFiles,
  exportFile,
  mimeFor,
} from "../files/library";
import type { LocalFile } from "../sync/types";
import { base64 } from "../files/bytes";
import { isTauri } from "../protocol/http";
const confirmation = useConfirmationStore();
const settings = useSettingsStore(),
  mode = ref<"local" | "server" | "connected">("local"),
  busy = ref(false),
  error = ref(""),
  status = ref(""),
  showConfig = ref(false);
const files = ref<Omit<LocalFile, "bytes">[]>([]),
  items = ref<RemoteFile[]>([]),
  path = ref(""),
  roots = ref<string[]>([]),
  truncated = ref(false);
const selected = ref<RemoteFile | null>(null),
  local = ref<LocalFile | null>(null),
  preview = ref(""),
  image = ref(""),
  destination = ref(""),
  action = ref("rename"),
  newName = ref(""),
  newText = ref(""),
  create = ref(false),
  createType = ref("file"),
  loaded = ref(false);
const encode = (text: string) => new TextEncoder().encode(text);
const canGoUp = computed(() => {
  try {
    return (
      loaded.value &&
      normalizePath(path.value) !== normalizePath(settings.settings.fileRoot)
    );
  } catch {
    return false;
  }
});
const client = () => new FileClient({ ...settings.settings });
const title = computed(
  () => local.value?.name ?? selected.value?.name ?? "文件",
);
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
async function loadLocal() {
  files.value = (await getRepository().listFiles()).sort(
    (a, b) => b.addedAt - a.addedAt,
  );
}
async function browse(next = path.value || settings.settings.fileRoot) {
  const result = await client().list(next);
  path.value = normalizePath(next);
  loaded.value = true;
  items.value = result.items.sort(
    (a, b) =>
      Number(b.type === "directory") - Number(a.type === "directory") ||
      a.name.localeCompare(b.name),
  );
  truncated.value = result.truncated;
  selected.value = null;
  preview.value = "";
}
async function importLocal(event: Event) {
  const input = event.target as HTMLInputElement;
  const chosen = [...(input.files ?? [])];
  input.value = "";
  await task(async () => {
    for (const f of chosen)
      await addFile(
        f.name,
        new Uint8Array(await f.arrayBuffer()),
        f.type || mimeFor(f.name),
      );
    await loadLocal();
    status.value = `已导入 ${chosen.length} 个文件；相同内容不重复存储`;
  });
}
async function openLocal(id: string) {
  await task(async () => {
    local.value = (await getRepository().getFile(id)) ?? null;
    if (!local.value) throw new Error("文件不存在");
    image.value = local.value.mime.startsWith("image/")
      ? `data:${local.value.mime};base64,${base64(local.value.bytes)}`
      : "";
    preview.value = /^(text\/|application\/(json|xml))/.test(local.value.mime)
      ? new TextDecoder().decode(local.value.bytes)
      : "";
  });
}
function selectRemote(file: RemoteFile) {
  selected.value = file;
  destination.value = file.path;
  action.value = "rename";
  preview.value = "";
  image.value = "";
}
async function openRemote(file: RemoteFile) {
  if (file.type === "directory") {
    await task(() => browse(file.path));
    return;
  }
  selectRemote(file);
}
function back() {
  local.value = null;
  selected.value = null;
  preview.value = "";
  image.value = "";
  create.value = false;
}
async function editOperation() {
  if (!selected.value) return;
  const file = selected.value;
  if (
    !(await confirmation.ask({
      title: "确认文件操作",
      body: `将执行${action.value === "copy" ? "复制" : action.value === "move" ? "移动" : "重命名"}：\n${file.path}\n→ ${destination.value}`,
      label: "确认执行",
    }))
  )
    return;
  await task(async () => {
    await client().rename(
      file.path,
      destination.value,
      action.value === "copy",
      action.value === "move",
    );
    await browse();
    status.value = "服务器已确认操作完成";
  });
}
async function remoteDelete() {
  if (
    !selected.value ||
    !(await confirmation.ask({
      title: "移入服务器回收站",
      body: `将此项目移到服务器回收站？\n${selected.value.path}`,
      label: "移入回收站",
      danger: true,
    }))
  )
    return;
  const file = selected.value;
  await task(async () => {
    await client().remove(file.path);
    await browse();
    status.value = "服务器已确认移入回收站";
  });
}
async function upload(event: Event) {
  const input = event.target as HTMLInputElement,
    f = input.files?.[0];
  input.value = "";
  if (!f) return;
  await task(async () => {
    const result = await client().upload(
      joinPath(path.value, f.name),
      new Uint8Array(await f.arrayBuffer()),
    );
    await browse();
    status.value = `已上传：${String(result.details.path ?? f.name)}（已有同名文件会保留）`;
  });
}
async function exportLocal() {
  if (!local.value) return;
  const f = local.value;
  await task(async () => {
    status.value = `已保存副本：${await exportFile(f)}`;
  });
}
async function removeLocal() {
  if (
    !local.value ||
    !(await confirmation.ask({
      title: "移除本机文件",
      body: "从本机文件库移除？已有聊天记录中的内容不删除。",
      label: "从文件库移除",
      danger: true,
    }))
  )
    return;
  const id = local.value.id;
  await task(async () => {
    await getRepository().deleteFile(id);
    back();
    await loadLocal();
    status.value = "已从本机文件库移除";
  });
}
onMounted(() => {
  path.value = settings.settings.fileRoot;
  void loadLocal();
});
</script>
<template>
  <section class="page">
    <header class="page-header detail-header">
      <button
        v-if="local || selected || create"
        type="button"
        class="icon-button"
        aria-label="返回文件列表"
        @click="back"
      >
        <AppIcon name="back" />
      </button><RouterLink v-else to="/me" class="icon-button" aria-label="返回我"><AppIcon name="back" /></RouterLink>
      <div>
        <h1>{{ title }}</h1>
      </div>
    </header>
    <div class="page-scroll files-content">
      <div v-if="!local && !selected && !create" class="segmented">
        <button
          type="button"
          :aria-pressed="mode === 'local'"
          @click="mode = 'local'"
        >
          本机附件
        </button><button type="button" :aria-pressed="mode === 'connected'" @click="mode = 'connected'">连接文件夹</button>
        <button
          type="button"
          :aria-pressed="mode === 'server'"
          @click="mode = 'server'"
        >
          服务器文件
        </button>
      </div>
      <p v-if="busy" class="form-status" role="status">正在处理…</p>
      <p v-if="error" class="error-line" role="alert">{{ error }}</p>
      <p v-if="status" class="file-status" role="status">{{ status }}</p>
      <template v-if="local">
        <div class="card form-stack">
          <p class="hint">
            {{ local.mime }} · {{ (local.size / 1024).toFixed(1) }} KB
          </p>
          <img v-if="image" :src="image" class="file-image" alt="文件预览" />
          <pre v-if="preview" class="file-preview">{{ preview }}</pre>
          <p v-if="!preview && !image" class="hint">
            此类型保留原文件，可导出后在系统应用中打开。
          </p>
          <button
            class="primary"
            type="button"
            :disabled="busy"
            @click="exportLocal"
          >
            导出原文件副本
          </button><button
            v-if="isTauri() && status"
            class="ghost"
            type="button"
            @click="
              task(async () => {
                const { invoke } = await import('@tauri-apps/api/core');
                status = String(await invoke('show_exports'));
              })
            "
          >
            查看导出位置
          </button><button
            class="text-button danger-text"
            type="button"
            :disabled="busy"
            @click="removeLocal"
          >
            从本机文件库移除
          </button>
        </div>
      </template>
      <template v-else-if="selected">
        <div class="card form-stack">
          <p class="file-path">{{ selected.path }}</p>
          <p class="hint">
            {{
              selected.size === null
                ? ""
                : `${(selected.size / 1024).toFixed(1)} KB`
            }}
            · {{ selected.modified }}
          </p>
          <button
            v-if="selected.type === 'file'"
            class="ghost"
            type="button"
            :disabled="busy"
            @click="
              task(async () => {
                const r = await client().read(selected!);
                preview = r.text;
                image = r.image;
              })
            "
          >
            读取内容 / 文档提取
          </button><img
            v-if="image"
            :src="image"
            class="file-image"
            alt="服务器图片预览"
          />
          <pre v-if="preview" class="file-preview">{{ preview }}</pre>
          <button
            v-if="selected.type === 'file'"
            class="primary"
            type="button"
            :disabled="busy"
            @click="
              task(async () => {
                const file = selected!;
                const bytes = await client().download(file);
                await addFile(
                  file.name,
                  bytes,
                  mimeFor(file.name),
                  '服务器下载',
                );
                status = '原文件已下载到本机附件';
                await loadLocal();
              })
            "
          >
            下载原文件到本机
          </button>
          <p v-if="selected.type === 'file'" class="hint">
            原文件下载需位于服务器的 file/ 分发目录；提取文本不等于原文件。
          </p>
        </div>
        <form class="card form-stack" @submit.prevent="editOperation">
          <label class="field">操作<select v-model="action">
            <option value="rename">重命名</option>
            <option v-if="selected.type === 'file'" value="copy">复制</option>
            <option value="move">移动</option>
          </select></label><label class="field">目标绝对路径<input
            v-model="destination"
            type="text"
            autocapitalize="none"
          /></label><button class="ghost" type="submit" :disabled="busy">
            确认执行
          </button>
        </form>
        <button
          class="text-button danger-text"
          type="button"
          :disabled="busy"
          @click="remoteDelete"
        >
          移入服务器回收站
        </button>
      </template>
      <template v-else-if="create">
        <form
          class="card form-stack"
          @submit.prevent="
            task(async () => {
              const result =
                createType === 'folder'
                  ? await client().folder(joinPath(path, newName))
                  : await client().upload(
                    joinPath(path, newName),
                    encode(newText),
                  );
              create = false;
              await browse();
              status = `已创建：${String(result.details.path ?? newName)}`;
            })
          "
        >
          <label class="field">类型<select v-model="createType">
            <option value="file">文本文件</option>
            <option value="folder">文件夹</option>
          </select></label><label class="field">新名称<input
            v-model="newName"
            required
            placeholder="笔记.md"
          /></label><label v-if="createType === 'file'" class="field">内容<textarea v-model="newText" rows="12" /></label><button class="primary" type="submit" :disabled="busy">
            创建（保留同名文件）
          </button>
        </form>
      </template>
      <template v-else-if="mode === 'local'">
        <div class="file-actions">
          <label class="primary file-action">导入文件<input
            class="sr-only"
            type="file"
            multiple
            aria-label="导入本机文件"
            :disabled="busy"
            @change="importLocal"
          /></label><button
            class="ghost"
            type="button"
            :disabled="busy"
            @click="
              task(async () => {
                const count = await collectHistoryFiles();
                await loadLocal();
                status = `已收集 ${count} 个聊天附件副本，聊天记录未改动`;
              })
            "
          >
            收集已有聊天附件
          </button>
        </div>
        <div v-if="files.length" class="settings-group">
          <button
            v-for="file in files"
            :key="file.id"
            class="settings-row"
            type="button"
            :disabled="busy"
            @click="openLocal(file.id)"
          >
            <span class="setting-icon"><AppIcon name="notes" /></span><span><strong>{{ file.name }}</strong><small>{{ (file.size / 1024).toFixed(1) }} KB ·
              {{ file.source }}</small></span><AppIcon name="chevron" :size="18" />
          </button>
        </div>
        <div v-else class="empty compact">
          <AppIcon name="folder" :size="36" />
          <h2>把文件带在身边</h2>
          <p>导入文件或收集聊天附件；不会上传到服务器。</p>
        </div>
      </template>
      <template v-else-if="mode === 'connected'"><ConnectedFolders /></template>
      <template v-else>
        <button class="ghost" type="button" @click="showConfig = !showConfig">
          {{ showConfig ? "收起连接设置" : "连接与目录设置" }}
        </button>
        <div v-if="showConfig" class="card form-stack">
          <RouterLink to="/settings/connection">配置 VCP 服务器与 API Key</RouterLink><label class="field">文件工具名称<input
            v-model="settings.settings.fileToolName"
            placeholder="ServerFileOperator"
            @change="
              settings.patch({ fileToolName: settings.settings.fileToolName })
            "
          /></label><label class="field">起始目录（服务器绝对路径）<input
            v-model="settings.settings.fileRoot"
            autocapitalize="none"
            placeholder="/home/user/project"
            @change="
              settings.patch({ fileRoot: settings.settings.fileRoot });
              path = settings.settings.fileRoot;
            "
          /></label>
          <p class="hint">作为本页浏览起点，实际文件权限由服务器决定。</p>
          <button
            class="ghost"
            type="button"
            :disabled="busy"
            @click="
              task(async () => {
                roots = await client().roots();
              })
            "
          >
            读取服务端允许目录
          </button><button
            v-for="root in roots"
            :key="root"
            class="file-root"
            type="button"
            @click="
              settings.patch({ fileRoot: root });
              path = root;
            "
          >
            {{ root }}
          </button><label class="field">File Key（原文件下载）<input
            v-model="settings.settings.fileKey"
            type="password"
            autocomplete="off"
            @change="
              settings.patch({ fileKey: settings.settings.fileKey })
            "
          /></label><label class="field">服务端 file/ 目录的绝对路径<input
            v-model="settings.settings.fileShareRoot"
            autocapitalize="none"
            placeholder="/home/user/VCPToolBox/file"
            @change="
              settings.patch({
                fileShareRoot: settings.settings.fileShareRoot,
              })
            "
          /></label>
          <p class="hint">
            这两个字段只用于原文件分发，不影响列目录和读写工具。
          </p>
        </div>
        <form class="file-browse" @submit.prevent="task(() => browse())">
          <label class="sr-only" for="server-path">服务器目录</label><input
            id="server-path"
            v-model="path"
            autocapitalize="none"
            placeholder="服务器目录"
          /><button
            class="icon-button"
            type="submit"
            aria-label="读取目录"
            :disabled="busy"
          >
            <AppIcon name="sync" />
          </button>
        </form>
        <div v-if="path && loaded" class="file-actions">
          <button
            class="ghost"
            type="button"
            :disabled="busy || !canGoUp"
            @click="
              task(() => browse(path.slice(0, path.lastIndexOf('/')) || '/'))
            "
          >
            上一级
          </button><label class="ghost file-action">上传文件<input
            class="sr-only"
            type="file"
            aria-label="上传文件到服务器"
            :disabled="busy"
            @change="upload"
          /></label><button
            class="ghost"
            type="button"
            @click="
              create = true;
              createType = 'file';
              newName = '';
              newText = '';
            "
          >
            新建
          </button>
        </div>
        <div v-if="items.length" class="settings-group">
          <div v-for="file in items" :key="file.path" class="remote-row">
            <button
              class="settings-row"
              type="button"
              :disabled="busy"
              @click="openRemote(file)"
            >
              <span class="setting-icon"><AppIcon
                :name="
                  file.type === 'directory' ? 'folder' : 'notes'
                "
              /></span><span><strong>{{ file.name }}</strong><small>{{
                file.type === "directory"
                  ? "文件夹"
                  : `${((file.size ?? 0) / 1024).toFixed(1)} KB`
              }}</small></span><AppIcon name="chevron" :size="18" />
            </button><button
              v-if="file.type === 'directory'"
              class="icon-button"
              type="button"
              :aria-label="`管理文件夹 ${file.name}`"
              :disabled="busy"
              @click="selectRemote(file)"
            >
              <AppIcon name="more" />
            </button>
          </div>
        </div>
        <p v-if="truncated" class="hint">
          服务器截断了目录列表，未显示全部项目。
        </p>
        <p v-if="!items.length" class="section-note">
          {{
            loaded
              ? "此目录为空，可以上传或新建文件。"
              : "填写起点并读取目录。文件操作直接执行，不经过模型。"
          }}
        </p>
      </template>
    </div>
  </section>
</template>
<style scoped>
.remote-row {
  display: flex;
  align-items: center;
}
.remote-row > .settings-row {
  flex: 1;
  min-width: 0;
}
.remote-row > .icon-button {
  flex-shrink: 0;
  margin-right: 8px;
}
.files-content {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.file-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}
.file-actions > .primary,
.file-actions > .ghost {
  font-size: 13px;
  min-height: 42px;
}
.file-browse {
  display: flex;
  gap: 8px;
}
.file-browse > input {
  flex: 1;
  min-width: 0;
  min-height: 44px;
  padding: 10px 14px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--bg-raise);
  color: var(--ink);
  font: inherit;
}
.file-preview {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  max-height: 50vh;
  overflow: auto;
  font: 13px/1.7 var(--mono);
  margin: 0;
}
.file-image {
  max-width: 100%;
  max-height: 45vh;
  object-fit: contain;
}
.file-path,
.file-status,
.file-root {
  overflow-wrap: anywhere;
  font-size: 13px;
  line-height: 1.6;
}
.file-status {
  color: var(--accent);
  background: var(--glass);
  padding: 12px;
  border-radius: 12px;
}
.file-root {
  text-align: left;
  color: var(--accent);
}
.detail-header h1 {
  font-size: 22px;
  overflow-wrap: anywhere;
}
.danger-text {
  color: var(--danger);
}
</style>
