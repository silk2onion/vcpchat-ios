<script setup lang="ts">
import { computed, ref } from "vue";
import type { LogEntry } from "../domain";
import { activityData, activityKind, activityPayload, activityTitle, record, text } from "../protocol/activity";
import { optionsKey, renderOptionsFrom } from "../render/options";
import { useLogStore } from "../stores/logs";
import { useSettingsStore } from "../stores/settings";
import AppIcon from "./AppIcon.vue";
import RichMarkdown from "./RichMarkdown.vue";
const props = defineProps<{ entry: LogEntry }>();
const logs = useLogStore(); const settings = useSettingsStore();
const data = computed(() => activityData(props.entry));
const kind = computed(() => activityKind(props.entry));
const results = computed(() => Array.isArray(data.value.results) ? data.value.results.map(record) : []);
const args = computed(() => record(data.value.args));
const options = computed(() => renderOptionsFrom(settings.settings));
const renderKey = computed(() => optionsKey(options.value));
const reason = ref(""); const sending = ref(false); const error = ref(""); const copied = ref(false);
const status = computed(() => logs.approvalStatus(props.entry));
const approvalLabels = { pending: "待审批", sent: "已发送 · 等待确认", approved: "已允许", rejected: "已拒绝", expired: "已过期" };
const kinds = { log: { icon: "logs", label: "VCPLog" }, approval: { icon: "shield", label: "工具审批" }, rag: { icon: "database", label: "RAG 知识库" }, thinking: { icon: "brain", label: "元思考链" }, agent: { icon: "agents", label: "Agent 会话" }, memory: { icon: "notes", label: "记忆检索" }, dream: { icon: "moon", label: "Agent 梦境" }, notification: { icon: "bell", label: "通知" }, error: { icon: "info", label: "错误" } };
const body = computed(() => {
  const d = data.value;
  const value = d.extractedMemories ?? d.narrative ?? d.error ?? d.content ?? d.message ?? d.text ?? d.summary ?? d.result ?? d.reason ?? d.query;
  return typeof value === "string" ? value : value ? JSON.stringify(value, null, 2) : "";
});
const messages = computed(() => Array.isArray(data.value.messages) ? data.value.messages.map(record) : data.value.type === "AGENT_PRIVATE_CHAT_PREVIEW" ? [{ role: "USER", content: data.value.query }, { role: "AI RESPONSE", content: data.value.response }] : []);
const steps = computed(() => Array.isArray(data.value.stages) ? data.value.stages.map(record) : []);
const seeds = computed(() => Array.isArray(data.value.seeds) ? data.value.seeds.map(record) : []);
const associations = computed(() => Array.isArray(data.value.associations) ? data.value.associations.map(record) : []);
const operations = computed(() => Array.isArray(data.value.operations) ? data.value.operations.map(record) : []);
async function respond(approved: boolean) {
  sending.value = true; error.value = "";
  try { await logs.respond(props.entry.id, approved, reason.value); }
  catch (caught) { error.value = caught instanceof Error ? caught.message : "审批未发送"; }
  finally { sending.value = false; }
}
async function copy() {
  try { await navigator.clipboard.writeText(JSON.stringify(activityPayload(props.entry), null, 2)); copied.value = true; }
  catch { error.value = "复制失败，请在原始数据中选择文本"; }
}
</script>
<template>
  <article class="activity-card" :class="[`activity-${kind}`, { 'approval-pending': kind === 'approval' && status === 'pending' }]">
    <header class="activity-card-header"><span class="event-icon"><AppIcon :name="kinds[kind].icon" :size="20" /></span><div><small>{{ kinds[kind].label }}</small><h3>{{ activityTitle(entry) }}</h3></div><time>{{ new Date(entry.createdAt).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }) }}</time></header>
    <template v-if="kind === 'approval' && data.type === 'tool_approval_request'">
      <div class="event-metadata"><span v-if="text(data.maid || data.agentName)"><AppIcon name="agents" :size="14" />{{ text(data.maid || data.agentName) }}</span><span v-if="text(args.command)">{{ text(args.command) }}</span><span class="approval-state" :class="status">{{ approvalLabels[status] }}</span></div>
      <p v-if="text(data.reason || data.aiReason)" class="event-explanation">{{ text(data.reason || data.aiReason) }}</p>
      <div v-if="text(args.path || args.filePath || args.url)" class="approval-target">{{ text(args.path || args.filePath || args.url) }}</div>
      <details class="event-details" open><summary>调用参数</summary><pre>{{ JSON.stringify(args, null, 2) }}</pre></details>
      <div v-if="data.changePreview" class="approval-preview"><h4>变更预览</h4><pre>{{ JSON.stringify(data.changePreview, null, 2) }}</pre></div>
      <template v-if="status === 'pending'">
        <label class="field approval-reason"><span>给 Agent 的说明 <small>可选</small></span><textarea v-model="reason" rows="2" maxlength="1000" placeholder="例如：只读检查可以，先不要修改文件" :aria-label="`审批说明 ${text(data.toolName)}`" /></label>
        <div class="approval-actions"><button class="ghost danger" type="button" :disabled="sending" @click="respond(false)"><AppIcon name="close" :size="17" />拒绝</button><button class="primary" type="button" :disabled="sending" @click="respond(true)"><AppIcon name="check" :size="17" />{{ sending ? '发送中…' : '允许一次' }}</button></div>
      </template>
      <p v-else-if="entry.decision" class="hint">{{ entry.decision.approved ? '允许' : '拒绝' }}{{ entry.decision.reason ? `：${entry.decision.reason}` : '' }}</p>
    </template>
    <template v-else-if="kind === 'rag'">
      <div class="event-metadata"><span v-if="data.k != null">K {{ data.k }}</span><span v-if="data.useRerank">ReRank</span><span v-if="data.useBM25">BM25 {{ text(data.bm25Mode) }}</span><span v-if="data.useTagMemo">TagBoost</span><span v-if="data.useRiverMemo">RiverMemo</span><span v-if="data.fromCache">缓存命中</span><span v-if="data.useTime">时间检索</span></div>
      <div v-if="Array.isArray(data.coreTags)" class="event-tags"><span v-for="tag in data.coreTags" :key="String(tag)">{{ tag }}</span></div>
      <div v-if="text(data.query)" class="rag-query"><small>检索问题</small><RichMarkdown :key="renderKey" :source="text(data.query)" :options="options" safe /></div>
      <div class="rag-result-heading"><strong>{{ results.length }} 条相关记录</strong><AppIcon name="database" :size="16" /></div>
      <details v-for="(result, index) in results" :key="index" class="rag-result" :open="index < 2"><summary><span class="result-index">{{ String(index + 1).padStart(2, '0') }}</span><span>{{ text(result.source || result.fileName || result.title) || '知识片段' }}</span><strong :class="{ 'high-score': typeof result.score === 'number' && result.score >= 0.8 }">{{ typeof result.score === 'number' ? result.score.toFixed(3) : '时间' }}</strong></summary><div class="rag-result-content"><p v-if="typeof result.originalScore === 'number'" class="meta">原始分数 {{ result.originalScore.toFixed(3) }}</p><RichMarkdown :key="renderKey" :source="text(result.text || result.content || result.pageContent)" :options="options" safe /></div></details>
      <p v-if="!results.length" class="hint">本次检索没有返回记录。</p>
    </template>
    <template v-else-if="kind === 'agent' && messages.length"><div v-for="(message, index) in messages" :key="index" class="observer-message"><small>{{ text(message.name || message.role) }}</small><RichMarkdown :key="renderKey" :source="text(message.content)" :options="options" safe /></div></template>
    <template v-else-if="kind === 'thinking'">
      <RichMarkdown v-if="text(data.query)" :key="renderKey" :source="text(data.query)" :options="options" safe />
      <div v-for="(step, index) in steps" :key="index" class="observer-step"><span>{{ step.stage ?? index + 1 }}</span><div><strong>{{ text(step.clusterName) }}</strong><p class="meta">{{ step.resultCount ?? (Array.isArray(step.results) ? step.results.length : 0) }} 个结果</p><div v-for="(result, resultIndex) in (Array.isArray(step.results) ? step.results.map(record) : [])" :key="resultIndex" class="observer-message"><small>{{ text(result.source) }} · {{ typeof result.score === 'number' ? result.score.toFixed(3) : '无分数' }}</small><RichMarkdown :key="renderKey" :source="text(result.text)" :options="options" safe /></div></div></div>
    </template>
    <template v-else>
      <div v-if="kind === 'memory'" class="event-metadata"><span v-if="data.diaryCount != null">{{ data.diaryCount }} 条日记</span><span v-if="data.mode">{{ text(data.mode) }}</span><span v-if="data.action">{{ text(data.action) }}</span></div>
      <div v-if="kind === 'dream'" class="event-metadata"><span v-if="data.dreamId">{{ text(data.dreamId) }}</span><span v-if="data.seedCount != null">{{ data.seedCount }} 个种子</span><span v-if="data.associationCount != null">{{ data.associationCount }} 次联想</span><span v-if="data.fullLength != null">{{ data.fullLength }} 字</span><span v-if="data.operationCount != null">{{ data.operationCount }} 项操作</span></div>
      <RichMarkdown v-if="body" :key="renderKey" class="event-body" :source="body" :options="options" safe />
      <div v-for="(seed, index) in seeds" :key="`seed-${index}`" class="observer-message"><small>{{ text(seed.file) }}</small><RichMarkdown :key="renderKey" :source="text(seed.snippet)" :options="options" safe /></div>
      <div v-for="(association, index) in associations" :key="`association-${index}`" class="event-metadata"><span>{{ text(association.file) }}</span><span>{{ text(association.score) }}</span></div>
      <div v-for="(operation, index) in operations" :key="`operation-${index}`" class="event-metadata"><span>{{ text(operation.type) }}</span><span>{{ text(operation.operationId) }}</span><span>{{ text(operation.status) }}</span></div>
    </template>
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
    <details class="event-raw"><summary>原始数据</summary><button class="text-button" type="button" @click="copy"><AppIcon name="copy" :size="14" />{{ copied ? '已复制' : '复制 JSON' }}</button><pre>{{ JSON.stringify(activityPayload(entry), null, 2) }}</pre></details>
  </article>
</template>
