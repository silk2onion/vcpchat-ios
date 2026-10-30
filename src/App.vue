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
import { pageTransition, primaryTabs, tabIsActive } from "./ui/navigation";

const route = useRoute();
const workspace = useWorkspaceStore();
const speech = useSpeechStore();
const transition = ref("page-tab");
watch(() => route.path, (next, previous) => {
  transition.value = pageTransition(next, previous);
});
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
      <RouterView v-slot="{ Component, route: current }"><Transition :name="transition" mode="out-in"><div :key="current.path" class="route-surface"><component :is="Component" /></div></Transition></RouterView>
    </main>
    <nav class="tabbar" aria-label="主导航">
      <RouterLink
        v-for="tab in primaryTabs"
        :key="tab.to"
        :to="tab.to"
        :class="{ active: tabIsActive(tab.to, route.path) }"
        :aria-current="tabIsActive(tab.to, route.path) ? 'page' : undefined"
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
