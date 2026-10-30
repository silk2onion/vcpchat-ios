<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from "vue";
import AppIcon from "./AppIcon.vue";
defineProps<{ title: string; subtitle?: string }>();
const emit = defineEmits<{ close: [] }>();
const dialog = ref<HTMLElement | null>(null);
let previous: HTMLElement | null = null;
function onKey(event: KeyboardEvent) {
  if (event.key === "Escape") {
    event.preventDefault();
    emit("close");
  }
  if (event.key !== "Tab") return;
  const nodes = [
    ...(dialog.value?.querySelectorAll<HTMLElement>(
      "button:not(:disabled), input:not(:disabled), textarea, select, a[href]",
    ) ?? []),
  ].filter((node) => node.getClientRects().length > 0);
  if (!nodes.length) {
    event.preventDefault();
    return;
  }
  if (
    event.shiftKey &&
    (document.activeElement === nodes[0] ||
      document.activeElement === dialog.value)
  ) {
    event.preventDefault();
    nodes.at(-1)?.focus();
  } else if (!event.shiftKey && document.activeElement === nodes.at(-1)) {
    event.preventDefault();
    nodes[0]?.focus();
  }
}
onMounted(() => {
  previous =
    document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
  dialog.value?.focus({ preventScroll: true });
});
onBeforeUnmount(() => previous?.focus({ preventScroll: true }));
</script>
<template>
  <Teleport to="body">
    <div class="sheet-overlay" @click.self="$emit('close')">
      <section
        ref="dialog"
        class="app-sheet"
        role="dialog"
        aria-modal="true"
        :aria-label="title"
        tabindex="-1"
        @keydown="onKey"
      >
        <div class="sheet-handle" />
        <header class="sheet-header">
          <div>
            <h2>{{ title }}</h2>
            <p v-if="subtitle">{{ subtitle }}</p>
          </div>
          <button
            class="icon-button subtle"
            type="button"
            aria-label="关闭面板"
            @click="$emit('close')"
          >
            <AppIcon name="close" />
          </button>
        </header>
        <div class="sheet-body"><slot /></div>
        <div v-if="$slots.footer" class="sheet-footer">
          <slot name="footer" />
        </div>
      </section>
    </div>
  </Teleport>
</template>
