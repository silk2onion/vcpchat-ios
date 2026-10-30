<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import type { GroupMode } from "../domain";
import { useLibraryStore } from "../stores/library";
import { useWorkspaceStore } from "../stores/workspace";
import { shortDate, useChatNavigation } from "../ui/navigation";
import AgentAvatar from "./AgentAvatar.vue";
import AppIcon from "./AppIcon.vue";
import AppSheet from "./AppSheet.vue";

const library = useLibraryStore();
const workspace = useWorkspaceStore();
const router = useRouter();
const route = useRoute();
const { openTopic, newChat } = useChatNavigation();
const name = ref("");
const avatar = ref("");
const description = ref("");
const prompt = ref("");
const model = ref("");
const temperature = ref("");
const makePrimary = ref(false);
const members = ref<string[]>([]);
const mode = ref<GroupMode>("mention");
const query = ref("");
const error = ref("");
const busy = ref(false);
const action = ref<"menu" | "rename" | "delete">("menu");
const selectedAgent = computed(() => {
  const sheet = workspace.sheet;
  return sheet?.type === "agent"
    ? library.agents.find((a) => a.id === sheet.id)
    : undefined;
});
const selectedGroup = computed(() => {
  const sheet = workspace.sheet;
  return sheet?.type === "group"
    ? library.groups.find((g) => g.id === sheet.id)
    : undefined;
});
const selectedTopic = computed(() => {
  const sheet = workspace.sheet;
  return sheet?.type === "topic-options"
    ? library.topics.find((t) => t.id === sheet.id)
    : undefined;
});
const choices = computed(() =>
  library.agents.filter((a) =>
    a.name.toLowerCase().includes(query.value.trim().toLowerCase()),
  ),
);
const title = computed(() => {
  if (action.value === "delete") return "确认删除";
  if (action.value === "rename") return "重命名会话";
  switch (workspace.sheet?.type) {
    case "agent":
      return selectedAgent.value ? "Agent 资料" : "创建 Agent";
    case "group":
      return selectedGroup.value ? "群聊设置" : "创建群聊";
    case "new-chat":
      return "开始新会话";
    case "main-agent":
      return "更换主 Agent";
    case "topics":
      return "切换会话";
    default:
      return "会话选项";
  }
});
watch(
  () => workspace.sheet,
  () => {
    const agent = selectedAgent.value;
    const group = selectedGroup.value;
    name.value = agent?.name ?? group?.name ?? selectedTopic.value?.title ?? "";
    avatar.value = agent?.avatar ?? "";
    description.value = agent?.description ?? "";
    prompt.value = agent?.systemPrompt ?? "";
    model.value = agent?.model ?? "";
    temperature.value =
      agent?.temperature == null ? "" : String(agent.temperature);
    members.value = [...(group?.memberIds ?? [])];
    mode.value = group?.mode ?? "mention";
    makePrimary.value = false;
    query.value = "";
    error.value = "";
    action.value = "menu";
  },
  { immediate: true },
);

async function run(task: () => Promise<void>) {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  try {
    await task();
  } catch (caught) {
    error.value = caught instanceof Error ? caught.message : String(caught);
  } finally {
    busy.value = false;
  }
}
function close() {
  if (!busy.value) workspace.close();
}
async function choose(type: "agent" | "group", id: string) {
  await run(async () => {
    await newChat(type, id);
    workspace.close();
  });
}
async function saveAgent() {
  if (!name.value.trim()) {
    error.value = "给 Agent 起个名字。";
    return;
  }
  const value = temperature.value.trim() ? Number(temperature.value) : null;
  if (value !== null && (!Number.isFinite(value) || value < 0 || value > 2)) {
    error.value = "Temperature 需要在 0 到 2 之间。";
    return;
  }
  await run(async () => {
    let agent = selectedAgent.value;
    if (!agent) {
      await library.createAgent(name.value);
      agent = library.currentAgent ?? undefined;
    }
    if (!agent) return;
    await library.saveAgent({
      ...agent,
      name: name.value.trim(),
      avatar: avatar.value.trim(),
      description: description.value.trim(),
      systemPrompt: prompt.value,
      model: model.value.trim(),
      temperature: value,
    });
    if (makePrimary.value) await library.setMainAgent(agent.id);
    workspace.close();
  });
}
async function saveGroup() {
  if (!name.value.trim() || !members.value.length) {
    error.value = "填写群聊名称，并至少选一位 Agent。";
    return;
  }
  await run(async () => {
    if (selectedGroup.value)
      await library.saveGroup({
        ...selectedGroup.value,
        name: name.value.trim(),
        memberIds: members.value,
        mode: mode.value,
      });
    else await library.createGroup(name.value, members.value, mode.value);
    workspace.close();
  });
}
async function remove() {
  await run(async () => {
    if (selectedAgent.value) await library.removeAgent(selectedAgent.value.id);
    else if (selectedGroup.value)
      await library.removeGroup(selectedGroup.value.id);
    else if (selectedTopic.value) {
      workspace.clearDraft(selectedTopic.value.id);
      await library.removeTopic(selectedTopic.value.id);
    }
    if (route.path.startsWith("/chat"))
      await router.replace(`/chat/${encodeURIComponent(library.topicId)}`);
    workspace.close();
  });
}
</script>
<template>
  <AppSheet
    v-if="workspace.sheet"
    :title="title"
    :subtitle="
      workspace.sheet.type === 'main-agent'
        ? '主 Agent 是你的固定入口，更换不会移动任何会话。'
        : undefined
    "
    @close="close"
  >
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
    <template v-if="action === 'delete'">
      <div class="delete-confirm">
        <AppIcon name="trash" :size="32" />
        <h3>{{ name }}</h3>
        <p>
          {{
            selectedAgent || selectedGroup
              ? "这个 Agent 或群聊的本机会话也会被删除。"
              : "这个会话及其中的消息会从本机删除。"
          }}
        </p>
      </div>
    </template>
    <form
      v-else-if="action === 'rename'"
      id="rename-form"
      class="stack"
      @submit.prevent="
        run(async () => {
          if (selectedTopic) await library.renameTopic(name, selectedTopic.id);
          workspace.close();
        })
      "
    >
      <label class="field">会话名称<input v-model="name" type="text" maxlength="100" /></label>
    </form>
    <template
      v-else-if="
        workspace.sheet.type === 'new-chat' ||
          workspace.sheet.type === 'main-agent'
      "
    >
      <label class="search-field"><AppIcon name="search" :size="18" /><input
        v-model="query"
        type="search"
        aria-label="选择 Agent"
        placeholder="搜索 Agent"
      /></label>
      <button
        v-for="agent in choices"
        :key="agent.id"
        class="choice-row"
        type="button"
        :disabled="busy"
        @click="
          workspace.sheet.type === 'main-agent'
            ? run(async () => {
              await library.setMainAgent(agent.id);
              workspace.close();
            })
            : choose('agent', agent.id)
        "
      >
        <AgentAvatar :name="agent.name" :symbol="agent.avatar" /><span
          class="conversation-copy"
        ><strong>{{ agent.name }}</strong><span>{{
          agent.description || agent.model || "使用默认模型"
        }}</span></span><span v-if="agent.id === library.mainAgent?.id" class="badge">主 Agent</span><AppIcon v-else name="chevron" :size="18" />
      </button>
      <template
        v-if="workspace.sheet.type === 'new-chat' && library.groups.length"
      >
        <div class="list-heading"><h3>群聊</h3></div>
        <button
          v-for="group in library.groups.filter((g) => g.name.includes(query))"
          :key="group.id"
          class="choice-row"
          type="button"
          @click="choose('group', group.id)"
        >
          <AgentAvatar :name="group.name" group /><span
            class="conversation-copy"
          ><strong>{{ group.name }}</strong><span>{{ group.memberIds.length }} 位 Agent</span></span><AppIcon name="chevron" :size="18" />
        </button>
      </template>
      <p v-if="!choices.length" class="section-note">没有找到这个 Agent。</p>
    </template>
    <form
      v-else-if="workspace.sheet.type === 'agent'"
      id="agent-form"
      class="stack form-stack"
      @submit.prevent="saveAgent"
    >
      <div class="profile-preview">
        <AgentAvatar
          :name="name || 'Agent'"
          :symbol="avatar"
          :size="68"
        /><label class="field avatar-field">头像符号<input
          v-model="avatar"
          type="text"
          maxlength="8"
          placeholder="例如 ✦"
          aria-label="头像符号"
        /></label>
      </div>
      <label class="field">名字<input
        v-model="name"
        type="text"
        maxlength="64"
        placeholder="给 Agent 起个名字"
      /></label>
      <label class="field">简介<input
        v-model="description"
        type="text"
        maxlength="100"
        placeholder="它擅长什么"
      /></label>
      <label class="field">模型<input
        v-model="model"
        type="text"
        placeholder="留空使用设置里的默认模型"
      /></label>
      <label class="field">系统提示<textarea
        v-model="prompt"
        rows="5"
        placeholder="这个 Agent 的角色、语气和工作方式"
      />
      </label>
      <label class="field">Temperature<input
        v-model="temperature"
        type="number"
        min="0"
        max="2"
        step="0.1"
        placeholder="使用默认值"
      /></label>
      <label v-if="!selectedAgent" class="check"><input v-model="makePrimary" type="checkbox" />创建后设为主
        Agent</label>
      <button
        v-else-if="selectedAgent.id !== library.mainAgent?.id"
        class="setting-action"
        type="button"
        @click="
          run(async () => {
            if (selectedAgent) await library.setMainAgent(selectedAgent.id);
          })
        "
      >
        <AppIcon name="star" />设为主 Agent<AppIcon name="chevron" :size="18" />
      </button>
      <span v-else class="badge main-profile-badge"><AppIcon name="star" :size="14" />当前主 Agent</span>
      <button
        v-if="selectedAgent"
        class="danger text-button"
        type="button"
        @click="action = 'delete'"
      >
        删除 Agent
      </button>
    </form>
    <form
      v-else-if="workspace.sheet.type === 'group'"
      id="group-form"
      class="stack form-stack"
      @submit.prevent="saveGroup"
    >
      <label class="field">群聊名称<input
        v-model="name"
        type="text"
        maxlength="64"
        placeholder="例如 灵感圆桌"
      /></label>
      <label class="field">发言方式<select v-model="mode">
        <option value="mention">@点名，否则轮流</option>
        <option value="rotate">轮流一位</option>
        <option value="all">每位依次回复</option>
      </select></label>
      <h3 class="form-label">参与的 Agent</h3>
      <label v-for="agent in library.agents" :key="agent.id" class="choice-row"><AgentAvatar
        :name="agent.name"
        :symbol="agent.avatar"
        :size="36"
      /><span class="conversation-copy"><strong>{{ agent.name }}</strong></span><input
        v-model="members"
        type="checkbox"
        :value="agent.id"
        :aria-label="`选择 ${agent.name}`"
      /></label>
      <button
        v-if="selectedGroup"
        class="danger text-button"
        type="button"
        @click="action = 'delete'"
      >
        删除群聊
      </button>
    </form>
    <template v-else-if="workspace.sheet.type === 'topics'">
      <button
        class="setting-action"
        type="button"
        @click="choose(library.ownerType, library.ownerId)"
      >
        <AppIcon name="plus" />新建会话
      </button><button
        v-for="topic in library.ownerTopics"
        :key="topic.id"
        class="choice-row"
        type="button"
        @click="
          run(async () => {
            await openTopic(topic.id);
            workspace.close();
          })
        "
      >
        <span class="conversation-copy"><strong>{{ topic.title }}</strong><span>{{ shortDate(topic.updatedAt)
        }}<template v-if="library.runningTopics.includes(topic.id)">
          · 正在回复</template></span></span><AppIcon
          v-if="topic.id === library.topicId"
          name="check"
          :size="20"
        />
      </button>
    </template>
    <template v-else-if="workspace.sheet.type === 'topic-options'">
      <button class="setting-action" type="button" @click="action = 'rename'">
        <AppIcon name="edit" />重命名会话<AppIcon
          name="chevron"
          :size="18"
        />
      </button><button
        class="setting-action danger"
        type="button"
        @click="action = 'delete'"
      >
        <AppIcon name="trash" />删除会话
      </button>
    </template>
    <template
      v-if="
        action !== 'menu' ||
          workspace.sheet.type === 'agent' ||
          workspace.sheet.type === 'group'
      "
      #footer
    >
      <button class="ghost" type="button" :disabled="busy" @click="close">
        取消
      </button>
      <button
        v-if="action === 'delete'"
        class="danger-fill"
        type="button"
        :disabled="busy"
        @click="remove"
      >
        确认删除
      </button>
      <button
        v-else
        class="primary"
        type="submit"
        :form="
          action === 'rename'
            ? 'rename-form'
            : workspace.sheet.type === 'agent'
              ? 'agent-form'
              : 'group-form'
        "
        :disabled="busy"
      >
        {{ busy ? "保存中…" : "保存" }}
      </button>
    </template>
  </AppSheet>
</template>
