<script setup lang="ts">
import ConversationList from "../components/ConversationList.vue";
import AgentAvatar from "../components/AgentAvatar.vue";
import AppIcon from "../components/AppIcon.vue";
import { useLibraryStore } from "../stores/library";
import { useChatNavigation } from "../ui/navigation";
const library = useLibraryStore();
const { openOwner } = useChatNavigation();
</script>
<template>
  <ConversationList class="mobile-home" />
  <section class="desktop-welcome" aria-label="开始对话">
    <template v-if="library.mainAgent">
      <AgentAvatar
        :name="library.mainAgent.name"
        :symbol="library.mainAgent.avatar"
        :image="library.mainAgent.avatarUrl"
        :size="80"
      /><span class="main-agent-label"><AppIcon name="star" :size="14" /> 你的主 Agent</span>
      <h1>{{ library.mainAgent.name }}</h1>
      <p>今天，想从什么开始？</p>
      <button
        class="primary"
        type="button"
        @click="openOwner('agent', library.mainAgent.id)"
      >
        开始对话 <AppIcon name="chevron" :size="18" />
      </button>
    </template>
  </section>
</template>
