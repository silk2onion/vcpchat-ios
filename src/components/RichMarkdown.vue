<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { renderMarkdown, renderSafeMarkdown } from "../protocol/markdown";
import { enhance } from "../render/enhance";
import type { RenderOptions } from "../render/options";

const props = defineProps<{
  source: string;
  options: RenderOptions;
  streaming?: boolean;
  safe?: boolean;
  caret?: boolean;
}>();

const root = ref<HTMLElement | null>(null);
const visible = ref(typeof IntersectionObserver === "undefined");
const html = computed(() => (props.safe ? renderSafeMarkdown(props.source) : renderMarkdown(props.source)));
let release: (() => void) | null = null;
let observer: IntersectionObserver | null = null;
let run = 0;

async function upgrade() {
  const element = root.value;
  if (!element || props.streaming || !visible.value || !props.options.rich) return;
  run += 1;
  const current = run;
  release?.();
  release = null;
  const cleanup = await enhance(element, props.options);
  if (current === run) release = cleanup;
  else cleanup();
}

onMounted(() => {
  if (!visible.value && root.value) {
    observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        visible.value = true;
        observer?.disconnect();
        observer = null;
      },
      { rootMargin: "600px 0px" },
    );
    observer.observe(root.value);
  }
  void upgrade();
});

watch([html, () => props.streaming, visible], () => void upgrade(), { flush: "post" });

onBeforeUnmount(() => {
  run += 1;
  observer?.disconnect();
  release?.();
});
</script>

<template>
  <div ref="root" class="prose" :class="{ caret }" v-html="html" />
</template>
