<script setup lang="ts">
import { computed, ref } from "vue";
import { useNotesStore } from "../stores/notes";
import AppIcon from "../components/AppIcon.vue";

const notes = useNotesStore();
const mode = ref<"local" | "server">("local");
const query = ref("");
const active = computed(() => notes.notes.find((note) => note.id === notes.activeId) ?? null);
const title = ref("");
const body = ref("");

function openLocal(id: string) {
  notes.activeId = id;
  const note = notes.notes.find((item) => item.id === id);
  title.value = note?.title ?? "";
  body.value = note?.body ?? "";
}

if (notes.activeId) openLocal(notes.activeId);

async function save() {
  if (!active.value) return;
  await notes.saveLocal({ ...active.value, title: title.value.trim() || "未命名笔记", body: body.value });
}
</script>

<template>
  <section class="screen">
    <header class="spread notes-header">
      <RouterLink to="/me" class="icon-button" aria-label="返回我"><AppIcon name="back" /></RouterLink>
      <h1>笔记</h1>
      <div class="segmented" role="tablist">
        <button type="button" :aria-pressed="mode === 'local'" @click="mode = 'local'">本机</button>
        <button type="button" :aria-pressed="mode === 'server'" @click="mode = 'server'">服务器日记</button>
      </div>
    </header>
    <p v-if="notes.error" class="error-line">{{ notes.error }}</p>
    <div v-if="mode === 'local'" class="note-layout">
      <div class="stack">
        <button class="primary" type="button" @click="notes.createLocal().then(() => notes.activeId && openLocal(notes.activeId))">新笔记</button>
        <button v-for="note in notes.notes" :key="note.id" class="note-button" :class="{ active: note.id === notes.activeId }" type="button" @click="openLocal(note.id)">
          <strong>{{ note.title }}</strong>
          <div class="hint">{{ note.body.slice(0, 42) || "空白" }}</div>
        </button>
        <p v-if="!notes.notes.length" class="hint">本机还没有笔记。它们不会上传，除非你自己复制到服务器日记。</p>
      </div>
      <form v-if="active" class="stack" @submit.prevent="save">
        <input v-model="title" type="text" aria-label="笔记标题" />
        <textarea v-model="body" aria-label="笔记正文" />
        <div class="row">
          <button class="primary" type="submit">保存到本机</button>
          <button class="danger" type="button" @click="notes.removeLocal(active.id)">删除</button>
        </div>
      </form>
      <div v-else class="empty">
        <h2>从一条本地笔记开始</h2>
        <p class="hint">适合还没配置管理员账号时先记下来。</p>
      </div>
    </div>
    <div v-else class="stack">
      <p class="hint">服务器日记需要在设置 → 身份与日记中填写管理员账号。</p>
      <div class="row">
        <button class="primary" type="button" :disabled="notes.loading" @click="notes.refreshFolders()">{{ notes.loading ? "读取中" : "刷新文件夹" }}</button>
        <select v-model="notes.remoteFolder" aria-label="日记文件夹" @change="notes.refreshRemote()">
          <option value="">选择文件夹</option>
          <option v-for="folder in notes.folders" :key="folder" :value="folder">{{ folder }}</option>
        </select>
      </div>
      <form class="row" @submit.prevent="notes.search(query)">
        <input v-model="query" type="text" placeholder="搜索日记" aria-label="搜索日记" />
        <button class="ghost" type="submit">搜索</button>
      </form>
      <button v-for="note in notes.remote" :key="`${note.folder}/${note.file}`" class="note-button" type="button" @click="notes.openRemote(note)">
        <strong>{{ note.file }}</strong>
        <div class="hint">{{ note.preview || note.lastModified || note.folder }}</div>
      </button>
      <p v-if="!notes.remote.length && !notes.loading" class="hint">还没有列出日记。刷新文件夹，或确认管理员凭据。</p>
      <form class="stack" @submit.prevent="notes.saveRemote()">
        <input v-model="notes.remoteFile" type="text" placeholder="文件名，例如 晨记" aria-label="日记文件名" />
        <textarea v-model="notes.remoteBody" aria-label="日记正文" placeholder="写进服务器的正文" />
        <button class="primary" type="submit" :disabled="notes.loading || !notes.remoteFolder">保存到服务器</button>
      </form>
    </div>
  </section>
</template>
<style scoped>
.notes-header{gap:10px;flex-wrap:wrap}.notes-header h1{flex:1}.notes-header .segmented{margin-left:auto}
</style>
