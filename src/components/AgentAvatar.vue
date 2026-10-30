<script setup lang="ts">
import { computed } from "vue";
import AppIcon from "./AppIcon.vue";
const props = withDefaults(
  defineProps<{
    name: string;
    symbol?: string;
    image?: string;
    size?: number;
    group?: boolean;
    personal?: boolean;
  }>(),
  { size: 44, symbol: "", image: "", group: false, personal: false },
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
  ><img v-if="image" :src="image" alt="" /><AppIcon v-else-if="group" name="agents" :size="size * 0.52" /><AppIcon v-else-if="personal" name="person" :size="size * 0.52" /><template
    v-else
  >{{ initial }}</template></span>
</template>
