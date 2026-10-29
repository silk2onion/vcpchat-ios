<script setup lang="ts">
import { computed } from "vue";
import { renderMarkdown } from "../protocol/markdown";
import { parseSegments } from "../protocol/tools";

const props = defineProps<{
  content: string;
  reasoning: string;
  streaming?: boolean;
}>();

const segments = computed(() => parseSegments(props.content));

function html(text: string) {
  return renderMarkdown(text);
}
</script>

<template>
  <details v-if="reasoning" class="think" :open="streaming">
    <summary>思考</summary>
    <pre>{{ reasoning }}</pre>
  </details>
  <template v-for="(segment, index) in segments" :key="index">
    <div v-if="segment.type === 'text'" class="prose" :class="{ caret: streaming && index === segments.length - 1 }" v-html="html(segment.text)" />
    <details v-else-if="segment.type === 'think'" class="think" :open="!segment.closed">
      <summary>思考过程{{ segment.closed ? "" : " · 进行中" }}</summary>
      <pre>{{ segment.text }}</pre>
    </details>
    <details v-else-if="segment.type === 'tool'" class="tool" open>
      <summary>{{ segment.closed ? "工具" : "工具 · 输入中" }} · {{ segment.name }}<span v-if="segment.command"> · {{ segment.command }}</span></summary>
      <pre>{{ segment.body }}</pre>
    </details>
    <details v-else class="result" open>
      <summary>{{ segment.closed ? "工具结果" : "工具结果 · 接收中" }}</summary>
      <pre>{{ segment.text }}</pre>
    </details>
  </template>
  <span v-if="streaming && !content" class="caret" />
</template>
