<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { activityData, activityKind } from "../protocol/activity";
import { useLogStore } from "../stores/logs";
import { useWorkspaceStore } from "../stores/workspace";
import AppSheet from "./AppSheet.vue";
import AppIcon from "./AppIcon.vue";
import ActivityCard from "./ActivityCard.vue";
const logs = useLogStore(); const workspace = useWorkspaceStore(); const router = useRouter();
const filter = ref("all"); const limit = ref(30);
const filters = computed(() => workspace.activityTab === "rag" ? [{ id: "all", name: "全部" }, { id: "rag", name: "知识库" }, { id: "thinking", name: "元思考" }, { id: "agent", name: "Agent" }, { id: "memory", name: "记忆" }, { id: "dream", name: "梦境" }] : [{ id: "all", name: "全部" }, { id: "pending", name: "待审批" }, { id: "notification", name: "通知" }, { id: "error", name: "错误" }, { id: "handled", name: "已处理" }]);
const entries = computed(() => [...logs.entries].reverse().filter((e) => {
  const kind = activityKind(e); const data = activityData(e);
  if (workspace.activityTab === "log") return e.channel === "log";
  if (workspace.activityTab === "rag") return ["rag", "thinking", "agent", "memory", "dream"].includes(kind) && (filter.value === "all" || kind === filter.value);
  if (filter.value === "pending") return data.type === "tool_approval_request" && logs.approvalStatus(e) === "pending";
  if (filter.value === "handled") return data.type === "tool_approval_request" && logs.approvalStatus(e) !== "pending";
  return !["rag", "thinking", "agent", "memory", "dream"].includes(kind) && data.type !== "connection_ack" && (filter.value === "all" || kind === filter.value);
}));
watch(() => workspace.activityTab, () => { filter.value = "all"; limit.value = 30; }, { flush: "sync" });
watch(() => workspace.activityOpen, (open) => { if (open) { if (logs.pending.length) { workspace.activityTab = "notifications"; filter.value = "pending"; } void logs.sync(); void logs.markRead(); } });
watch(() => logs.entries.at(-1)?.id, () => { if (workspace.activityOpen) void logs.markRead(); });
function configure() { workspace.closeActivity(); void router.push("/settings/logs"); }
</script>
<template>
  <AppSheet v-if="workspace.activityOpen" title="通知中心" variant="drawer" :closing="workspace.activityClosing" @close="workspace.closeActivity">
    <div class="activity-status-strip"><span><i :class="{ connected: logs.status.log === '已连接' }" />VCPLog <small>{{ logs.status.log }}</small></span><span><i :class="{ connected: logs.status.info === '已连接' }" />VCPInfo <small>{{ logs.status.info }}</small></span><button class="icon-button" type="button" aria-label="重新连接日志通道" @click="logs.reconnect"><AppIcon name="history" :size="18" /></button></div>
    <div class="activity-tabs" role="tablist" aria-label="通知中心分区"><button v-for="tab in [{ id: 'notifications', name: '通知', icon: 'bell' }, { id: 'log', name: 'VCPLog', icon: 'logs' }, { id: 'rag', name: 'RAG 监视器', icon: 'database' }] as const" :key="tab.id" role="tab" type="button" :aria-selected="workspace.activityTab === tab.id" @click="workspace.activityTab = tab.id"><AppIcon :name="tab.icon" :size="18" />{{ tab.name }}<span v-if="tab.id === 'notifications' && logs.pending.length" class="tab-count">{{ logs.pending.length }}</span></button></div>
    <div v-if="workspace.activityTab !== 'log'" class="activity-filters" aria-label="事件筛选"><button v-for="item in filters" :key="item.id" type="button" :aria-pressed="filter === item.id" @click="filter = item.id">{{ item.name }}<span v-if="item.id === 'pending' && logs.pending.length">{{ logs.pending.length }}</span></button></div>
    <div class="activity-list"><ActivityCard v-for="entry in entries.slice(0, limit)" :key="entry.id" :entry="entry" /><button v-if="entries.length > limit" type="button" class="ghost load-more" @click="limit += 30">再显示 30 条</button></div>
    <div v-if="!entries.length" class="activity-empty"><div class="observer-orbit"><AppIcon :name="workspace.activityTab === 'rag' ? 'database' : filter === 'pending' ? 'shield' : 'bell'" :size="35" /><i /><i /><i /></div><h3>{{ filter === 'pending' ? '没有待处理的审批' : workspace.activityTab === 'rag' ? '等待信息流接入' : '这里暂时很安静' }}</h3><p>{{ workspace.activityTab === 'rag' ? '知识库、元思考链和 Agent 事件会在这里展开。' : filter === 'pending' ? '需要你决定的工具调用会优先显示。' : '新事件到来时，右上角会亮起提示。' }}</p><button class="ghost" type="button" @click="configure">{{ logs.status.log === '已连接' ? '连接设置' : '连接日志通道' }}</button></div>
  </AppSheet>
</template>
