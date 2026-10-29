<script setup lang="ts">
import { useRoute } from "vue-router";

const route = useRoute();
const tabs = [
  { to: "/", label: "对话" },
  { to: "/notes", label: "笔记" },
  { to: "/logs", label: "日志" },
  { to: "/settings", label: "设置" },
];
</script>

<template>
  <div class="app-shell">
    <main class="app-main">
      <RouterView />
    </main>
    <nav class="tabbar" aria-label="主导航">
      <RouterLink v-for="tab in tabs" :key="tab.to" :to="tab.to" :class="{ active: route.path === tab.to }">{{ tab.label }}</RouterLink>
    </nav>
  </div>
</template>
