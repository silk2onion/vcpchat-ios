<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from "vue";
import { mountSandbox } from "../render/sandbox";

const props = defineProps<{ html: string }>();
const host = ref<HTMLElement | null>(null);
let destroy: (() => void) | null = null;

function mount() {
  destroy?.();
  destroy = host.value ? mountSandbox(host.value, props.html) : null;
}

onMounted(mount);
watch(() => props.html, mount);
onBeforeUnmount(() => destroy?.());
</script>

<template>
  <div ref="host" class="sandbox-host html-bubble" />
</template>
