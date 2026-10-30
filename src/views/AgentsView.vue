<script setup lang="ts">
import { computed, ref } from "vue";
import AgentAvatar from "../components/AgentAvatar.vue";
import AppIcon from "../components/AppIcon.vue";
import { useLibraryStore } from "../stores/library";
import { useWorkspaceStore } from "../stores/workspace";
import { useChatNavigation } from "../ui/navigation";
const library = useLibraryStore();
const workspace = useWorkspaceStore();
const { openOwner } = useChatNavigation();
const query = ref("");
const agents = computed(() =>
  [...library.agents]
    .sort(
      (a, b) =>
        Number(b.id === library.mainAgent?.id) -
        Number(a.id === library.mainAgent?.id),
    )
    .filter((a) =>
      `${a.name} ${a.description ?? ""}`.includes(query.value.trim()),
    ),
);
</script>
<template>
  <section class="page agents-page">
    <header class="page-header">
      <div>
        <p class="eyebrow">你的 AI 伙伴</p>
        <h1>Agent</h1>
      </div>
      <button
        class="icon-button accent-button"
        type="button"
        aria-label="添加 Agent"
        @click="workspace.open({ type: 'agent' })"
      >
        <AppIcon name="plus" />
      </button>
    </header>
    <div class="page-scroll">
      <label class="search-field"><AppIcon name="search" :size="19" /><input
        v-model="query"
        type="search"
        placeholder="找到你的 Agent"
        aria-label="搜索 Agent"
      /></label>
      <div class="list-heading">
        <h2>我的 Agent</h2>
        <span>{{ agents.length }}</span>
      </div>
      <div class="settings-group">
        <div v-for="agent in agents" :key="agent.id" class="agent-row">
          <button
            class="agent-row-open"
            type="button"
            @click="openOwner('agent', agent.id)"
          >
            <AgentAvatar :name="agent.name" :symbol="agent.avatar" :image="agent.avatarUrl" /><span
              class="conversation-copy"
            ><strong>{{ agent.name }}
              <span v-if="agent.id === library.mainAgent?.id" class="badge">主 Agent</span></strong><span>{{
              agent.description || agent.model || "使用默认模型"
            }}</span></span>
          </button>
          <button
            class="icon-button subtle"
            type="button"
            :aria-label="`编辑 ${agent.name}`"
            @click="workspace.open({ type: 'agent', id: agent.id })"
          >
            <AppIcon name="more" />
          </button>
        </div>
      </div>
      <div v-if="!agents.length" class="empty compact">
        <h2>没有找到这个 Agent</h2>
        <p>换个名字再试试。</p>
      </div>
      <div class="list-heading">
        <h2>群聊</h2>
        <button
          class="text-button"
          type="button"
          @click="workspace.open({ type: 'group' })"
        >
          <AppIcon name="plus" :size="16" /> 创建群聊
        </button>
      </div>
      <div v-if="library.groups.length" class="settings-group">
        <div v-for="group in library.groups" :key="group.id" class="agent-row">
          <button
            class="agent-row-open"
            type="button"
            @click="openOwner('group', group.id)"
          >
            <AgentAvatar :name="group.name" group /><span
              class="conversation-copy"
            ><strong>{{ group.name }}</strong><span>{{ group.memberIds.length }} 位 Agent ·
              {{
                { mention: "@点名发言", rotate: "轮流发言", all: "依次回复" }[
                  group.mode
                ]
              }}</span></span>
          </button><button
            class="icon-button subtle"
            type="button"
            :aria-label="`编辑群聊 ${group.name}`"
            @click="workspace.open({ type: 'group', id: group.id })"
          >
            <AppIcon name="more" />
          </button>
        </div>
      </div>
      <p v-else class="section-note">让不同的 Agent 在同一个会话里交流。</p>
    </div>
  </section>
</template>
