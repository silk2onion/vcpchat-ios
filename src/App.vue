<script setup lang="ts">
import { useRoute } from "vue-router";
import MediaViewer from "./components/MediaViewer.vue";
import ConversationList from "./components/ConversationList.vue";
import AppIcon from "./components/AppIcon.vue";
import WorkspaceSheet from "./components/WorkspaceSheet.vue";
import { useWorkspaceStore } from "./stores/workspace";

const route = useRoute();
const workspace = useWorkspaceStore();
const tabs = [
  { to: "/", label: "会话", icon: "chat" },
  { to: "/agents", label: "Agent", icon: "agents" },
  { to: "/notes", label: "笔记", icon: "notes" },
  { to: "/settings", label: "设置", icon: "settings" },
];
const active = (to: string) =>
  to === "/"
    ? route.path === "/" || route.path.startsWith("/chat")
    : route.path.startsWith(to) ||
      (to === "/settings" && route.path === "/logs");
</script>

<template>
  <div
    class="app-shell"
    :class="{ 'is-chat': route.path.startsWith('/chat') }"
    :inert="workspace.sheet ? true : undefined"
  >
    <aside class="desktop-sidebar"><ConversationList sidebar /></aside>
    <main class="app-main">
      <RouterView />
    </main>
    <nav class="tabbar" aria-label="主导航">
      <RouterLink
        v-for="tab in tabs"
        :key="tab.to"
        :to="tab.to"
        :class="{ active: active(tab.to) }"
      ><AppIcon :name="tab.icon" :size="22" /><span>{{
        tab.label
      }}</span></RouterLink>
    </nav>
  </div>
  <WorkspaceSheet />
  <MediaViewer />
</template>
