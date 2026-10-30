<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import AgentAvatar from "../components/AgentAvatar.vue";
import AppIcon from "../components/AppIcon.vue";
import ActivityButton from "../components/ActivityButton.vue";
import MessageBody from "../components/MessageBody.vue";
import { addFile } from "../files/library";
import { computeBinaryHash } from "../sync/upstream/hash.js";
import { assertAttachmentCount, attachmentKind } from "../protocol/messages";
import { createId } from "../protocol/ids";
import type { Attachment, ChatMessage, MessageStatus } from "../domain";
import { openViewer } from "../render/media";
import { optionsKey, renderOptionsFrom } from "../render/options";
import { useFrameMessages } from "../render/frame";
import { useLibraryStore } from "../stores/library";
import { useSettingsStore } from "../stores/settings";
import { useWorkspaceStore } from "../stores/workspace";
import { useSpeechStore } from "../stores/speech";
import { applyRules, turnDepths } from "../protocol/regex";
import { shouldSendOnEnter } from "../ui/composer";

const library = useLibraryStore();
const settings = useSettingsStore();
const workspace = useWorkspaceStore();
const speech = useSpeechStore();
const copied = ref("");
const route = useRoute();
const router = useRouter();
const displayedMessages = useFrameMessages(() => ({
  topicId: library.topicId,
  streaming: library.streaming,
  messages: library.messages,
}));
const depths = computed(() => turnDepths(displayedMessages.value));
function messageAgent(message: ChatMessage) {
  return library.agents.find((a) => a.id === message.agentId) ?? (library.ownerType === "agent" ? library.currentAgent ?? undefined : library.agents.find((a) => a.name === message.authorName));
}
function displayedText(message: ChatMessage) {
  const agent = messageAgent(message);
  return applyRules(message.content, [...settings.settings.regexRules, ...(agent?.regexRules ?? [])], "frontend", message.role, depths.value.get(message.id) ?? 0);
}
async function copyMessage(message: ChatMessage) {
  try { await navigator.clipboard.writeText(displayedText(message)); copied.value = message.id; }
  catch { library.error = "复制失败，请长按选择消息文本"; }
}
function readMessage(message: ChatMessage) {
  if (speech.messageId === message.id && speech.active) { speech.stop(); return; }
  if (!settings.settings.ttsUrl.trim()) { void router.push("/settings/speech"); return; }
  void speech.read(message.id, displayedText(message), messageAgent(message));
}
const draft = computed({
  get: () => workspace.draftFor(library.topicId).text,
  set: (text) => workspace.saveDraft(library.topicId, { text }),
});
const attachments = computed(
  () => workspace.draftFor(library.topicId).attachments,
);
const attachError = ref("");
const scroller = ref<HTMLElement | null>(null);
const input = ref<HTMLTextAreaElement | null>(null);
const fileInput = ref<HTMLInputElement | null>(null);
const following = ref(true);
const recipient = computed(() =>
  library.ownerType === "group" ? library.currentGroup : library.currentAgent,
);
const renderOptions = computed(() => renderOptionsFrom(settings.settings));
const renderKey = computed(() => optionsKey(renderOptions.value));
const statusLabels: Record<MessageStatus, string> = {
  complete: "",
  streaming: "正在回复",
  error: "发送失败",
  stopped: "已停止",
  interrupted: "已中断",
};

watch(
  () => route.params.topicId,
  async (id) => {
    if (typeof id === "string" && !library.topics.some((t) => t.id === id)) {
      await router.replace("/");
      return;
    }
    if (typeof id === "string" && id !== library.topicId)
      await library.selectTopic(id);
  },
  { immediate: true },
);
watch(
  () => library.topicId,
  async () => {
    attachError.value = "";
    following.value = true;
    await nextTick();
    bottom();
  },
);
watch(
  displayedMessages,
  async () => {
    const follow = following.value;
    await nextTick();
    if (follow) bottom();
  },
);
function bottom() {
  const el = scroller.value;
  if (el) el.scrollTop = el.scrollHeight;
  following.value = true;
}
function onScroll() {
  const el = scroller.value;
  if (el)
    following.value = el.scrollHeight - el.scrollTop - el.clientHeight < 100;
}
function grow() {
  const el = input.value;
  if (el) {
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 136)}px`;
  }
}
function canContinue(message: ChatMessage, index: number): boolean {
  return (
    !library.streaming &&
    message.role === "assistant" &&
    index === library.messages.length - 1 &&
    (message.status === "interrupted" ||
      (message.status === "stopped" && Boolean(message.content.trim())))
  );
}
async function submit() {
  if (library.streaming || (!draft.value.trim() && !attachments.value.length))
    return;
  if (!library.configured) {
    library.error = "先连接服务器，并选择一个模型。";
    return;
  }
  const text = draft.value;
  const files = attachments.value;
  workspace.clearDraft(library.topicId);
  following.value = true;
  if (input.value) input.value.style.height = "auto";
  await library.send(text, files);
}
function onKey(event: KeyboardEvent) {
  if (shouldSendOnEnter(event, settings.settings.enterSends)) {
    event.preventDefault();
    void submit();
  }
}
async function onFiles(event: Event) {
  const element = event.target as HTMLInputElement;
  const files = [...(element.files ?? [])];
  element.value = "";
  const topic = library.topicId;
  attachError.value = "";
  try {
    assertAttachmentCount(
      workspace.draftFor(topic).attachments.length,
      files.length,
    );
    const next = await Promise.all(
      files.map(async (file) => { const kind=attachmentKind(file);const data=await readFile(file,kind);const bytes=new Uint8Array(await file.arrayBuffer());data.hash=computeBinaryHash(bytes);await addFile(file.name,bytes,file.type);return data; }),
    );
    workspace.saveDraft(topic, {
      attachments: [...workspace.draftFor(topic).attachments, ...next],
    });
  } catch (error) {
    if (topic === library.topicId)
      attachError.value =
        error instanceof Error ? error.message : "附件没有读出来";
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
        mime:
          file.type ||
          (kind === "text" ? "text/plain" : "application/octet-stream"),
        kind,
        dataUrl: kind === "image" ? result : undefined,
        text: kind === "text" ? result : undefined,
      });
    };
    if (kind === "image") reader.readAsDataURL(file);
    else reader.readAsText(file);
  });
}
</script>
<template>
  <section class="chat-stage" aria-label="对话">
    <header class="chat-header">
      <button
        class="icon-button chat-back"
        type="button"
        aria-label="返回会话列表"
        @click="router.push('/')"
      >
        <AppIcon name="back" />
      </button>
      <button
        class="chat-identity"
        type="button"
        :aria-label="`查看 ${recipient?.name || 'Agent'} 资料`"
        @click="
          workspace.open(
            library.ownerType === 'group'
              ? { type: 'group', id: library.ownerId }
              : { type: 'agent', id: library.ownerId },
          )
        "
      >
        <AgentAvatar
          :name="recipient?.name || 'Agent'"
          :image="library.ownerType === 'agent' ? library.currentAgent?.avatarUrl : undefined"
          :symbol="
            library.ownerType === 'agent'
              ? library.currentAgent?.avatar
              : undefined
          "
          :size="38"
          :group="library.ownerType === 'group'"
        /><span><strong>{{ recipient?.name }}</strong><small>{{ library.currentTopic?.title || "新的对话" }}</small></span>
      </button>
      <button
        class="icon-button subtle"
        type="button"
        aria-label="切换会话"
        @click="workspace.open({ type: 'topics' })"
      >
        <AppIcon name="history" :size="21" />
      </button>
      <ActivityButton />
      <button
        class="icon-button subtle"
        type="button"
        aria-label="会话选项"
        @click="workspace.open({ type: 'topic-options', id: library.topicId })"
      >
        <AppIcon name="more" />
      </button>
    </header>
    <div v-if="!library.configured" class="connection-banner">
      <AppIcon name="server" :size="19" /><span>连接你的 VCPToolBox，开始对话</span><RouterLink to="/settings/connection">去连接<AppIcon name="chevron" :size="16" /></RouterLink>
    </div>
    <div v-if="library.error" class="chat-error" role="alert">
      <span>{{ library.error }}</span><button
        class="icon-button subtle"
        type="button"
        aria-label="关闭提示"
        @click="library.error = ''"
      >
        <AppIcon name="close" :size="16" />
      </button>
    </div>
    <div class="message-stage">
      <div
        ref="scroller"
        class="messages"
        :class="{ motion: renderOptions.motion }"
        @scroll.passive="onScroll"
      >
        <div v-if="!displayedMessages.length" class="empty-chat">
          <AgentAvatar
            :name="recipient?.name || 'Agent'"
            :image="library.ownerType === 'agent' ? library.currentAgent?.avatarUrl : undefined"
            :symbol="
              library.ownerType === 'agent'
                ? library.currentAgent?.avatar
                : undefined
            "
            :group="library.ownerType === 'group'"
            :size="70"
          />
          <h2>和{{ recipient?.name || "你的 Agent" }}聊聊</h2>
          <p>
            {{
              library.ownerType === "agent" && library.currentAgent?.description
                ? library.currentAgent.description
                : "新的会话，新的想法。"
            }}
          </p>
        </div>
        <article
          v-for="(message, index) in displayedMessages"
          :key="message.id"
          class="bubble"
          :class="[message.role, { streaming: message.status === 'streaming' }]"
          :data-message-id="message.id"
        >
          <header v-if="message.role === 'assistant'">
            <AgentAvatar
              :name="message.authorName || 'Agent'"
              :image="messageAgent(message)?.avatarUrl"
              :symbol="
                messageAgent(message)?.avatar
              "
              :size="24"
            /><strong>{{ message.authorName || "Agent" }}</strong><span
              v-if="statusLabels[message.status]"
              class="message-status"
              :class="message.status"
            ><span v-if="message.status === 'streaming'" class="live-dot" />{{
              statusLabels[message.status]
            }}</span>
          </header>
          <div class="body">
            <MessageBody
              :key="renderKey"
              :content="displayedText(message)"
              :reasoning="message.reasoning"
              :streaming="message.status === 'streaming'"
              :options="renderOptions"
            />
            <p v-if="message.syncNotice" class="hint">{{ message.syncNotice }}</p>
            <RouterLink v-if="message.attachments.some((a) => a.desktopOnly)" to="/files" class="text-button">桌面附件未下载 · 在文件页导入原文件</RouterLink>
            <div
              v-if="
                message.attachments.some(
                  (file) => file.kind === 'image' && file.dataUrl,
                )
              "
              class="attachment-strip"
            >
              <button
                v-for="file in message.attachments.filter(
                  (item) => item.kind === 'image' && item.dataUrl,
                )"
                :key="file.id"
                class="attachment-thumb"
                type="button"
                :aria-label="`预览 ${file.name}`"
                @click="
                  openViewer({
                    kind: 'image',
                    src: file.dataUrl ?? '',
                    alt: file.name,
                  })
                "
              >
                <img :src="file.dataUrl" :alt="file.name" loading="lazy" />
              </button>
            </div>
            <p
              v-if="message.attachments.some((file) => file.kind !== 'image' || !file.dataUrl)"
              class="hint"
            >
              附件：{{
                message.attachments
                  .filter((file) => file.kind !== "image" || !file.dataUrl)
                  .map((file) => file.name)
                  .join("、")
              }}
            </p>
            <p
              v-if="message.error && message.status !== 'streaming'"
              class="message-error"
            >
              {{ message.error }}
            </p>
            <button
              v-if="canContinue(message, index)"
              class="continue"
              type="button"
              @click="
                following = true;
                library.continueMessage(message.id);
              "
            >
              <AppIcon name="send" :size="16" />继续写
            </button>
          </div>
          <div v-if="message.status !== 'streaming'" class="message-actions"><button class="icon-button subtle" type="button" :aria-label="`复制消息 ${index + 1}`" @click="copyMessage(message)"><AppIcon :name="copied === message.id ? 'check' : 'copy'" :size="16" /></button><button v-if="message.role === 'assistant' && message.content.trim()" class="icon-button subtle" type="button" :class="{ 'is-speaking': speech.messageId === message.id && speech.active }" :aria-label="speech.messageId === message.id && speech.active ? '停止朗读这条消息' : `朗读回复 ${index + 1}`" @click="readMessage(message)"><AppIcon :name="speech.messageId === message.id && speech.active ? 'stop' : 'speaker'" :size="17" /></button></div>
        </article>
      </div>
      <button
        v-if="!following && displayedMessages.length"
        class="jump-latest"
        type="button"
        @click="bottom"
      >
        <AppIcon name="down" :size="18" />回到最新
      </button>
    </div>
    <div class="composer-dock">
      <p v-if="attachError" class="error-line" role="alert">
        {{ attachError }}
      </p>
      <div v-if="attachments.length" class="chips">
        <button
          v-for="file in attachments"
          :key="file.id"
          class="chip"
          type="button"
          :aria-label="`移除附件 ${file.name}`"
          @click="
            workspace.saveDraft(library.topicId, {
              attachments: attachments.filter((item) => item.id !== file.id),
            })
          "
        >
          {{ file.name }}<AppIcon name="close" :size="13" />
        </button>
      </div>
      <form class="composer" @submit.prevent="submit">
        <button
          class="icon-button subtle"
          type="button"
          aria-label="添加图片或文本附件"
          @click="fileInput?.click()"
        >
          <AppIcon name="plus" />
        </button><input
          ref="fileInput"
          hidden
          type="file"
          accept="image/*,.txt,.md,.json,.csv,.log,.xml,.yaml,.yml,text/*"
          multiple
          @change="onFiles"
        /><textarea
          ref="input"
          v-model="draft"
          rows="1"
          :placeholder="`发消息给 ${recipient?.name || 'Agent'}`"
          aria-label="消息"
          :enterkeyhint="settings.settings.enterSends ? 'send' : 'enter'"
          @keydown="onKey"
          @input="grow"
        /><button
          v-if="library.streaming"
          class="send-button stop-button"
          type="button"
          aria-label="停止生成"
          @click="library.stop()"
        >
          <AppIcon name="stop" :size="19" />
        </button><button
          v-else
          class="send-button"
          type="submit"
          aria-label="发送消息"
          :disabled="!draft.trim() && !attachments.length"
        >
          <AppIcon name="send" :size="21" />
        </button>
      </form>
      <p class="composer-meta">
        {{
          library.ownerType === "agent"
            ? library.currentAgent?.model ||
              settings.settings.defaultModel ||
              "未选择模型"
            : `${library.currentGroup?.memberIds.length || 0} 位 Agent`
        }}<span>对话保存在本机</span>
      </p>
    </div>
  </section>
</template>
