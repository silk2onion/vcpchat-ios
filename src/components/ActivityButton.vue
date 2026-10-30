<script setup lang="ts">
import { computed } from "vue";
import { useLogStore } from "../stores/logs";
import { useWorkspaceStore } from "../stores/workspace";
import AppIcon from "./AppIcon.vue";
const logs = useLogStore(); const workspace = useWorkspaceStore();
const count = computed(() => logs.pending.length || logs.unread);
</script>
<template>
  <button class="icon-button activity-button" type="button" :aria-label="`打开通知中心${logs.pending.length ? `，${logs.pending.length} 条待审批` : count ? `，${count} 条未读` : ''}`" @click="workspace.openActivity()"><AppIcon name="bell" :size="21" /><span v-if="count" class="activity-badge" :class="{ urgent: logs.pending.length }">{{ count > 99 ? '99+' : count }}</span></button>
</template>
