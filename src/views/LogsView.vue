<script setup lang="ts">
import { onMounted } from "vue";
import { useLogStore } from "../stores/logs";

const logs = useLogStore();
onMounted(() => {
  void logs.sync();
});
</script>

<template>
  <section class="screen">
    <header class="spread">
      <div>
        <p class="eyebrow">通道</p>
        <h1>VCP 日志</h1>
      </div>
      <button class="ghost" type="button" @click="logs.clear()">清空</button>
    </header>
    <div class="row">
      <span class="chip">VCPLog · {{ logs.status.log }}</span>
      <span class="chip">VCPInfo · {{ logs.status.info }}</span>
      <button class="primary" type="button" @click="logs.reconnect()">重新连接</button>
    </div>
    <p class="hint">地址形如 ws://主机:6005。应用会连到 /VCPlog/VCP_Key=… 和 /vcpinfo/VCP_Key=…，和桌面端同一条通道。密钥不会显示在这里。</p>
    <div v-if="!logs.entries.length" class="empty">
      <h2>还没有日志</h2>
      <p class="hint">填好 WebSocket 地址和密钥后，服务器推来的工具调用和状态会落在这张列表里。</p>
    </div>
    <div v-else class="log-list">
      <article v-for="entry in [...logs.entries].reverse()" :key="entry.id" class="log-item">
        <div class="spread">
          <strong>{{ entry.channel === "log" ? "Log" : "Info" }} · {{ entry.title }}</strong>
          <span class="meta">{{ new Date(entry.createdAt).toLocaleTimeString() }}</span>
        </div>
        <pre>{{ entry.detail }}</pre>
      </article>
    </div>
  </section>
</template>
