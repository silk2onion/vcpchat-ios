<script setup lang="ts">
import { computed } from "vue";
import AppIcon from "./AppIcon.vue";
const props = withDefaults(
  defineProps<{
    name: string;
    symbol?: string;
    size?: number;
    group?: boolean;
  }>(),
  { size: 44, symbol: "", group: false },
);
const tone = computed(
  () =>
    [...props.name].reduce((sum, char) => sum + (char.codePointAt(0) ?? 0), 0) %
    6,
);
const initial = computed(
  () => props.symbol || [...props.name.trim()][0] || "A",
);
</script>
<template>
  <span
    class="agent-avatar"
    :class="`avatar-tone-${tone}`"
    :style="{
      width: `${size}px`,
      height: `${size}px`,
      fontSize: `${size * 0.42}px`,
    }"
    aria-hidden="true"
  ><AppIcon v-if="group" name="agents" :size="size * 0.52" /><template
    v-else
  >{{ initial }}</template></span>
</template>
