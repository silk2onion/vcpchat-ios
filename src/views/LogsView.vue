<script setup lang="ts">
import { onMounted } from "vue";
import AppIcon from "../components/AppIcon.vue";
import { useLogStore } from "../stores/logs";
const logs = useLogStore();
onMounted(() => {
  void logs.sync();
});
async function clear() {
  if (confirm("清空本机保存的日志？")) await logs.clear();
}
</script>
<template>
  <section class="page logs-page">
    <header class="page-header detail-header">
      <RouterLink to="/settings" class="icon-button" aria-label="返回设置"><AppIcon name="back" /></RouterLink>
      <div><h1>实时日志</h1></div>
      <button
        class="icon-button subtle"
        type="button"
        aria-label="重新连接"
        @click="logs.reconnect()"
      >
        <AppIcon name="history" />
      </button>
    </header>
    <div class="page-scroll">
      <div class="log-channel-grid">
        <div
          v-for="channel in ['log', 'info'] as const"
          :key="channel"
          class="log-channel"
        >
          <strong>{{ channel === "log" ? "VCPLog" : "VCPInfo" }}</strong><span><i :class="{ connected: logs.status[channel] === '已连接' }" />{{
            logs.status[channel]
          }}</span>
        </div>
      </div>
      <div class="list-heading">
        <h2>最近事件 · {{ logs.entries.length }}</h2>
        <button
          v-if="logs.entries.length"
          class="text-button"
          type="button"
          @click="clear"
        >
          清空日志
        </button>
      </div>
      <div v-if="!logs.entries.length" class="empty">
        <AppIcon name="logs" :size="35" />
        <h2>等待服务器消息</h2>
        <p>运行状态与工具日志会出现在这里。</p>
        <RouterLink class="ghost" to="/settings/logs">配置日志连接</RouterLink>
      </div>
      <div v-else class="log-list">
        <article
          v-for="entry in [...logs.entries].reverse()"
          :key="entry.id"
          class="log-item"
        >
          <div class="spread">
            <strong><span class="badge">{{
                      entry.channel === "log" ? "Log" : "Info"
                    }}</span>
              {{ entry.title }}</strong><time class="meta">{{
              new Date(entry.createdAt).toLocaleTimeString("zh-CN", {
                hour: "2-digit",
                minute: "2-digit",
                second: "2-digit",
              })
            }}</time>
          </div>
          <pre>{{ entry.detail }}</pre>
        </article>
      </div>
    </div>
  </section>
</template>
