<script setup lang="ts">
import { computed, ref } from "vue";
import { useLibraryStore } from "../stores/library";
import { useWorkspaceStore } from "../stores/workspace";
import { shortDate, useChatNavigation } from "../ui/navigation";
import AgentAvatar from "./AgentAvatar.vue";
import AppIcon from "./AppIcon.vue";
import ActivityButton from "./ActivityButton.vue";
defineProps<{ sidebar?: boolean }>();
const library = useLibraryStore();
const workspace = useWorkspaceStore();
const { openTopic, openOwner } = useChatNavigation();
const query = ref("");
const owner = (type: string, id: string) =>
  (type === "agent" ? library.agents : library.groups).find(
    (item) => item.id === id,
  );
const topics = computed(() =>
  library.recentTopics.filter((topic) =>
    `${topic.title} ${owner(topic.ownerType, topic.ownerId)?.name ?? ""}`
      .toLowerCase()
      .includes(query.value.trim().toLowerCase()),
  ),
);
</script>
<template>
  <section
    class="conversation-panel"
    :class="{ 'sidebar-panel': sidebar }"
    aria-label="会话列表"
  >
    <header class="page-header">
      <div>
        <p class="eyebrow brand">VCPCHAT</p>
        <h1>会话</h1>
      </div>
      <div class="page-header-actions">
        <ActivityButton /><button
          class="icon-button accent-button"
          type="button"
          aria-label="新建会话"
          @click="workspace.open({ type: 'new-chat' })"
        >
          <AppIcon name="plus" />
        </button>
      </div>
    </header>
    <div class="panel-scroll">
      <div v-if="library.mainAgent" class="main-agent-card">
        <button
          type="button"
          class="main-agent-open"
          :aria-label="`打开主 Agent ${library.mainAgent.name}`"
          @click="openOwner('agent', library.mainAgent.id)"
        >
          <AgentAvatar
            :name="library.mainAgent.name"
            :symbol="library.mainAgent.avatar"
            :image="library.mainAgent.avatarUrl"
            :size="50"
          />
          <span class="main-agent-copy"><span class="main-agent-label"><AppIcon name="star" :size="12" /> 主 Agent</span><strong>{{ library.mainAgent.name }}</strong><span>随时回到这里</span></span>
        </button>
        <button
          class="icon-button subtle"
          type="button"
          aria-label="更换主 Agent"
          @click="workspace.open({ type: 'main-agent' })"
        >
          <AppIcon name="more" />
        </button>
      </div>
      <label class="search-field"><AppIcon name="search" :size="19" /><input
        v-model="query"
        type="search"
        placeholder="搜索会话或 Agent"
        aria-label="搜索会话或 Agent"
      /></label>
      <div class="list-heading">
        <h2>{{ query ? "搜索结果" : "最近会话" }}</h2>
        <span>{{ topics.length }}</span>
      </div>
      <div class="conversation-rows">
        <button
          v-for="topic in topics"
          :key="topic.id"
          type="button"
          class="conversation-row"
          :class="{ selected: sidebar && topic.id === library.topicId }"
          @click="openTopic(topic.id)"
        >
          <AgentAvatar
            :name="owner(topic.ownerType, topic.ownerId)?.name || 'Agent'"
            :image="topic.ownerType === 'agent' ? library.agents.find((a) => a.id === topic.ownerId)?.avatarUrl : undefined"
            :symbol="
              topic.ownerType === 'agent'
                ? library.agents.find((a) => a.id === topic.ownerId)?.avatar
                : undefined
            "
            :group="topic.ownerType === 'group'"
            :size="44"
          />
          <span class="conversation-copy"><strong>{{ topic.title }}</strong><span>{{ owner(topic.ownerType, topic.ownerId)?.name
          }}<template v-if="library.runningTopics.includes(topic.id)">
            · <span class="stream-label">正在回复</span></template></span></span>
          <span class="conversation-meta"><time>{{ shortDate(topic.updatedAt) }}</time><span
            v-if="library.runningTopics.includes(topic.id)"
            class="live-dot"
            aria-label="正在回复"
          /></span>
        </button>
      </div>
      <div v-if="!topics.length" class="empty compact">
        <AppIcon name="search" :size="30" />
        <h2>{{ query ? "没有找到会话" : "开始一段新对话" }}</h2>
        <p>
          {{
            query
              ? "试试 Agent 名字或会话标题"
              : "选择一个 Agent，聊聊你正在想的事。"
          }}
        </p>
      </div>
    </div>
  </section>
</template>
