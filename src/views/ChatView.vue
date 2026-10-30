<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import AgentDrawer from "../components/AgentDrawer.vue";
import MessageBody from "../components/MessageBody.vue";
import { assertAttachmentCount, attachmentKind } from "../protocol/messages";
import { createId } from "../protocol/ids";
import type { Attachment } from "../domain";
import { openViewer } from "../render/media";
import { optionsKey, renderOptionsFrom } from "../render/options";
import { useLibraryStore } from "../stores/library";
import { useSettingsStore } from "../stores/settings";

const library = useLibraryStore();
const settings = useSettingsStore();
const draft = ref("");
const attachments = ref<Attachment[]>([]);
const attachError = ref("");
const drawer = ref(false);
const wide = ref(window.matchMedia("(min-width: 960px)").matches);
const scroller = ref<HTMLElement | null>(null);
const renaming = ref(false);
const titleDraft = ref("");
const fileInput = ref<HTMLInputElement | null>(null);

const media = window.matchMedia("(min-width: 960px)");
media.addEventListener("change", () => {
  wide.value = media.matches;
});

const showDrawer = computed(() => wide.value || drawer.value);
const renderOptions = computed(() => renderOptionsFrom(settings.settings));
const renderKey = computed(() => optionsKey(renderOptions.value));

watch(
  () => library.messages.map((message) => message.content + message.reasoning).join(""),
  async () => {
    await nextTick();
    const el = scroller.value;
    if (!el) return;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 140;
    if (nearBottom || library.streaming) el.scrollTop = el.scrollHeight;
  },
);

async function submit() {
  const files = attachments.value;
  const text = draft.value;
  draft.value = "";
  attachments.value = [];
  await library.send(text, files);
}

function onKey(event: KeyboardEvent) {
  if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
    event.preventDefault();
    void submit();
  }
}

async function onFiles(event: Event) {
  const input = event.target as HTMLInputElement;
  const files = [...(input.files ?? [])];
  input.value = "";
  attachError.value = "";
  try {
    assertAttachmentCount(attachments.value.length, files.length);
    const next: Attachment[] = [];
    for (const file of files) {
      const kind = attachmentKind(file);
      next.push(await readFile(file, kind));
    }
    attachments.value = [...attachments.value, ...next];
  } catch (error) {
    attachError.value = error instanceof Error ? error.message : "附件没有读出来";
  }
}

function readFile(file: File, kind: "image" | "text"): Promise<Attachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error(`${file.name} 读取失败`));
    reader.onload = () => {
      const result = String(reader.result ?? "");
      resolve({
        id: createId("file"),
        name: file.name,
        mime: file.type || (kind === "text" ? "text/plain" : "application/octet-stream"),
        kind,
        dataUrl: kind === "image" ? result : undefined,
        text: kind === "text" ? result : undefined,
      });
    };
    if (kind === "image") reader.readAsDataURL(file);
    else reader.readAsText(file);
  });
}

async function saveTitle() {
  await library.renameTopic(titleDraft.value);
  renaming.value = false;
}
</script>

<template>
  <div :class="{ 'chat-wide': showDrawer && wide }">
    <div v-if="drawer && !wide" class="drawer-backdrop" @click="drawer = false" />
    <AgentDrawer v-if="showDrawer" @close="drawer = false" />
    <section class="chat-stage screen">
      <header class="screen-head">
        <button v-if="!wide" class="icon-button" type="button" aria-label="打开话题列表" @click="drawer = true">☰</button>
        <div style="flex: 1">
          <p class="eyebrow">{{ library.ownerType === "group" ? "群组" : "助手" }} · {{ library.currentAgent?.name || library.currentGroup?.name }}</p>
          <button v-if="!renaming" class="ghost" type="button" @click="titleDraft = library.currentTopic?.title || ''; renaming = true">
            {{ library.currentTopic?.title || "新的对话" }}
          </button>
          <form v-else class="row" @submit.prevent="saveTitle">
            <input v-model="titleDraft" type="text" aria-label="话题标题" />
            <button class="primary" type="submit">保存</button>
          </form>
        </div>
        <button class="ghost" type="button" @click="library.currentTopic && library.removeTopic(library.currentTopic.id)">删除话题</button>
      </header>
      <p v-if="!settings.settings.serverUrl || !settings.settings.apiKey" class="banner">
        服务器地址和 API Key 还空着。去设置里填上你自己的 VCPToolBox，密钥只留在这台设备。
      </p>
      <p v-if="library.error" class="error-line">{{ library.error }}</p>
      <div ref="scroller" class="messages" :class="{ motion: renderOptions.motion }">
        <div v-if="!library.messages.length" class="empty">
          <p class="eyebrow">还没有消息</p>
          <h2>把这句话发给你的服务器</h2>
          <p class="hint">回复按流式到达。工具标记会收成卡片，思考过程可以展开。</p>
        </div>
        <article v-for="message in library.messages" :key="message.id" class="bubble" :class="[message.role, { streaming: message.status === 'streaming' }]">
          <header>
            <strong>{{ message.authorName || (message.role === "user" ? "我" : "助手") }}</strong>
            <span class="meta">{{ message.status === "streaming" ? "正在写" : message.status === "error" ? "失败" : message.status === "stopped" ? "已停止" : "" }}</span>
          </header>
          <div class="body">
            <MessageBody :key="renderKey" :content="message.content" :reasoning="message.reasoning" :streaming="message.status === 'streaming'" :options="renderOptions" />
            <div v-if="message.attachments.some((file) => file.kind === 'image' && file.dataUrl)" class="attachment-strip">
              <button
                v-for="file in message.attachments.filter((item) => item.kind === 'image' && item.dataUrl)"
                :key="file.id"
                class="attachment-thumb"
                type="button"
                :aria-label="`预览 ${file.name}`"
                @click="openViewer({ kind: 'image', src: file.dataUrl ?? '', alt: file.name })"
              >
                <img :src="file.dataUrl" :alt="file.name" loading="lazy" />
              </button>
            </div>
            <p v-if="message.attachments.some((file) => file.kind !== 'image')" class="hint">
              附件：{{ message.attachments.filter((file) => file.kind !== "image").map((file) => file.name).join("、") }}
            </p>
            <p v-if="message.error && message.status !== 'streaming'" class="hint">{{ message.error }}</p>
          </div>
        </article>
      </div>
      <p v-if="attachError" class="error-line">{{ attachError }}</p>
      <div v-if="attachments.length" class="chips">
        <button v-for="file in attachments" :key="file.id" class="chip" type="button" @click="attachments = attachments.filter((item) => item.id !== file.id)">
          {{ file.name }} ×
        </button>
      </div>
      <form class="composer" @submit.prevent="submit">
        <button class="icon-button" type="button" aria-label="添加图片或文本附件" @click="fileInput?.click()">＋</button>
        <input ref="fileInput" hidden type="file" accept="image/*,.txt,.md,.json,.csv,.log,.xml,.yaml,.yml,text/*" multiple @change="onFiles" />
        <textarea v-model="draft" rows="2" placeholder="写给助手。Ctrl 或 ⌘ 加回车发送" aria-label="消息" @keydown="onKey" />
        <button v-if="library.streaming" class="danger" type="button" @click="library.stop()">停止</button>
        <button v-else class="primary" type="submit" :disabled="!draft.trim() && !attachments.length">发送</button>
      </form>
    </section>
  </div>
</template>
