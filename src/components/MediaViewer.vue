<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted } from "vue";
import { closeViewer, viewerItem } from "../render/media";

const item = computed(() => viewerItem.value);

function onKey(event: KeyboardEvent) {
  if (event.key === "Escape") closeViewer();
}

onMounted(() => window.addEventListener("keydown", onKey));
onBeforeUnmount(() => window.removeEventListener("keydown", onKey));
</script>

<template>
  <div v-if="item" class="viewer" role="dialog" aria-modal="true" :aria-label="item.alt || '预览'" @click.self="closeViewer">
    <button class="icon-button viewer-close" type="button" aria-label="关闭预览" @click="closeViewer">×</button>
    <img v-if="item.kind === 'image'" :src="item.src" :alt="item.alt" />
    <video v-else :src="item.src" controls playsinline autoplay />
    <p v-if="item.alt" class="hint">{{ item.alt }}</p>
  </div>
</template>
