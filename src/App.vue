<script setup lang="ts">
import { useRoute } from "vue-router";
import { ref, watch } from "vue";
import MediaViewer from "./components/MediaViewer.vue";
import ConversationList from "./components/ConversationList.vue";
import AppIcon from "./components/AppIcon.vue";
import WorkspaceSheet from "./components/WorkspaceSheet.vue";
import { useWorkspaceStore } from "./stores/workspace";
import AppWallpaper from "./components/AppWallpaper.vue";
import ActivityPanel from "./components/ActivityPanel.vue";
import SpeechPlayer from "./components/SpeechPlayer.vue";
import { useSpeechStore } from "./stores/speech";

const route = useRoute();
const workspace = useWorkspaceStore();
const speech = useSpeechStore();
const transition = ref("page-tab");
watch(() => route.path, (next, previous) => {
  transition.value = next === "/" && previous.startsWith("/chat") || next === "/settings" && previous.startsWith("/settings/") ? "page-back" : next.startsWith("/chat") || next.startsWith("/settings/") ? "page-forward" : "page-tab";
});
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
  <AppWallpaper />
  <div
    class="app-shell"
    :class="{ 'is-chat': route.path.startsWith('/chat'), 'has-speech': speech.active }"
    :inert="workspace.sheet || workspace.activityOpen ? true : undefined"
  >
    <aside class="desktop-sidebar"><ConversationList sidebar /></aside>
    <main class="app-main">
      <RouterView v-slot="{ Component, route: current }"><Transition :name="transition" mode="out-in"><component :is="Component" :key="current.path" /></Transition></RouterView>
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
  <ActivityPanel />
  <SpeechPlayer />
  <MediaViewer />
</template>
