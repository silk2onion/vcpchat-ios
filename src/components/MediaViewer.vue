<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { closeViewer, viewerItem } from "../render/media";
import AppIcon from "./AppIcon.vue";

const item = computed(() => viewerItem.value);
const zoom = ref(1);
const pan = ref({ x: 0, y: 0 });
const pointers = new Map<number, { x: number; y: number }>();
let distance = 0;
let initialZoom = 1;
let drag = { x: 0, y: 0 };
watch(item, () => {
  zoom.value = 1;
  pan.value = { x: 0, y: 0 };
  pointers.clear();
});
function setZoom(value: number) {
  zoom.value = Math.min(4, Math.max(1, value));
  if (zoom.value === 1) pan.value = { x: 0, y: 0 };
}
function pointerDown(event: PointerEvent) {
  if (item.value?.kind !== "image") return;
  (event.currentTarget as HTMLElement).setPointerCapture?.(event.pointerId);
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  drag = { x: event.clientX - pan.value.x, y: event.clientY - pan.value.y };
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    distance = Math.hypot(a.x - b.x, a.y - b.y);
    initialZoom = zoom.value;
  }
}
function pointerMove(event: PointerEvent) {
  if (!pointers.has(event.pointerId)) return;
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  if (pointers.size === 2 && distance > 0) {
    const [a, b] = [...pointers.values()];
    setZoom((initialZoom * Math.hypot(a.x - b.x, a.y - b.y)) / distance);
  } else if (pointers.size === 1 && zoom.value > 1) {
    const area = event.currentTarget as HTMLElement;
    const x = (area.clientWidth * (zoom.value - 1)) / 2;
    const y = (area.clientHeight * (zoom.value - 1)) / 2;
    pan.value = {
      x: Math.max(-x, Math.min(x, event.clientX - drag.x)),
      y: Math.max(-y, Math.min(y, event.clientY - drag.y)),
    };
  }
}
function pointerUp(event: PointerEvent) {
  pointers.delete(event.pointerId);
  const left = [...pointers.values()][0];
  if (left) drag = { x: left.x - pan.value.x, y: left.y - pan.value.y };
}

function onKey(event: KeyboardEvent) {
  if (event.key === "Escape") closeViewer();
}

onMounted(() => window.addEventListener("keydown", onKey));
onBeforeUnmount(() => window.removeEventListener("keydown", onKey));
</script>

<template>
  <div
    v-if="item"
    class="viewer"
    role="dialog"
    aria-modal="true"
    :aria-label="item.alt || '预览'"
    @click.self="closeViewer"
  >
    <button
      class="icon-button viewer-close"
      type="button"
      aria-label="关闭预览"
      @click="closeViewer"
    >
      <AppIcon name="close" />
    </button>
    <div
      v-if="item.kind === 'image'"
      class="image-viewport"
      @pointerdown="pointerDown"
      @pointermove="pointerMove"
      @pointerup="pointerUp"
      @pointercancel="pointerUp"
      @dblclick="setZoom(zoom === 1 ? 2 : 1)"
    >
      <img
        :src="item.src"
        :alt="item.alt"
        :style="{
          transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`,
        }"
        draggable="false"
      />
    </div>
    <video v-else :src="item.src" controls playsinline autoplay />
    <div v-if="item.kind === 'image'" class="image-zoom-controls">
      <button
        class="icon-button"
        type="button"
        aria-label="缩小图片"
        :disabled="zoom <= 1"
        @click="setZoom(zoom - 0.5)"
      >
        −
      </button><button
        class="text-button"
        type="button"
        aria-label="重置图片缩放"
        @click="setZoom(1)"
      >
        {{ Math.round(zoom * 100) }}%
      </button><button
        class="icon-button"
        type="button"
        aria-label="放大图片"
        :disabled="zoom >= 4"
        @click="setZoom(zoom + 0.5)"
      >
        <AppIcon name="plus" />
      </button>
    </div>
    <p v-if="item.alt" class="hint">{{ item.alt }}</p>
  </div>
</template>
