<script setup lang="ts">
import AppSheet from "./AppSheet.vue";
import { useConfirmationStore } from "../stores/confirmation";
const confirmation = useConfirmationStore();
</script>
<template>
  <AppSheet
    v-if="confirmation.prompt"
    :title="confirmation.prompt.title"
    :closing="confirmation.closing"
    @close="confirmation.settle(false)"
  >
    <p class="confirmation-body">{{ confirmation.prompt.body }}</p>
    <template #footer>
      <button
        class="ghost"
        type="button"
        :disabled="confirmation.closing"
        @click="confirmation.settle(false)"
      >
        取消
      </button><button
        class="primary"
        :class="{ 'danger-confirm': confirmation.prompt.danger }"
        type="button"
        :disabled="confirmation.closing"
        @click="confirmation.settle(true)"
      >
        {{ confirmation.prompt.label || "继续" }}
      </button>
    </template>
  </AppSheet>
</template>
<style scoped>
.confirmation-body {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  line-height: 1.7;
}
.danger-confirm {
  background: var(--danger);
  color: var(--bg);
}
</style>
