<script setup lang="ts">
import { onMounted, ref } from "vue";
import AppIcon from "../components/AppIcon.vue";
import { useSettingsStore } from "../stores/settings";
import { useSyncStore } from "../stores/sync";
import type { SyncMode } from "../sync/client";
const settings=useSettingsStore(),sync=useSyncStore();const mode=ref<SyncMode>("pull");const showToken=ref(false);const restoreError=ref("");
onMounted(()=>void sync.load());
async function restore(){if(!confirm("恢复本机到上次同步之前？仅影响这个同步来源，不回滚已经写到桌面的内容。"))return;try{await sync.restore();}catch(e){restoreError.value=e instanceof Error?e.message:String(e);}}
</script>
<template>
  <section class="page">
    <header class="page-header detail-header"><RouterLink to="/me" class="icon-button" aria-label="返回我"><AppIcon name="back" /></RouterLink><div><h1>桌面同步</h1></div></header>
    <div class="page-scroll form-stack">
      <p class="section-note">与 VCPChat 的 MobileSync 配对。现有本机会话保留，同步内容使用独立来源身份。</p>
      <form class="form-stack" @submit.prevent="sync.start(mode)">
        <fieldset class="card form-stack" :disabled="sync.busy">
          <label class="field">桌面 HTTP 地址<input v-model="settings.settings.syncHttpUrl" type="url" placeholder="http://192.168.1.8:5974" autocapitalize="none" @change="settings.patch({syncHttpUrl:settings.settings.syncHttpUrl});sync.load()" /></label>
          <label class="field">同步 WebSocket 地址<input v-model="settings.settings.syncWsUrl" type="url" placeholder="ws://192.168.1.8:5975/" autocapitalize="none" @change="settings.patch({syncWsUrl:settings.settings.syncWsUrl})" /></label>
          <label class="field">Mobile Sync Token<input v-model="settings.settings.syncToken" :type="showToken?'text':'password'" autocomplete="off" autocapitalize="none" @change="settings.patch({syncToken:settings.settings.syncToken})" /></label>
          <label class="check"><input v-model="showToken" type="checkbox" />显示 Token</label>
        </fieldset>
        <fieldset class="card form-stack" :disabled="sync.busy"><label class="field">同步方式<select v-model="mode" aria-label="同步方式"><option value="pull">从桌面拉取</option><option value="both">双向同步</option></select></label><p class="hint">{{ mode==='pull'?'拉取到独立的同步会话；本机已有改动时停止，不覆盖。':'将这个来源的会话与资料改动、删除写回桌面。原有本机会话不会自动上传。' }}</p></fieldset>
        <button class="primary wide-button" type="submit" :disabled="sync.busy">{{ sync.busy?'同步中…':'开始同步' }}</button><button v-if="sync.busy" class="ghost" type="button" @click="sync.cancel()">取消同步</button>
      </form>
      <div v-if="sync.phase||sync.summary||sync.error" class="card form-stack" aria-live="polite"><strong>{{ sync.phase }}</strong><p v-if="sync.summary">{{ sync.summary }}</p><p v-if="sync.error" class="error-line">{{ sync.error }}</p><p v-for="(warning,i) in sync.warnings" :key="i" class="hint">{{ warning }}</p></div>
      <p v-if="sync.lastSync" class="section-note">上次完成：{{ new Date(sync.lastSync).toLocaleString('zh-CN') }}</p>
      <button v-if="sync.canRestore" type="button" class="ghost" :disabled="sync.busy" @click="restore">恢复到上次同步前</button><p v-if="restoreError" class="error-line">{{ restoreError }}</p>
      <div class="card"><p class="hint">头像单独传输；历史附件只同步身份与提取内容，原文件需要在文件页导入。桌面须启用分布式服务和 VCPMobileSync（Wire 1.5）。同步在前台运行。</p></div>
    </div>
  </section>
</template>
<style scoped>fieldset{margin:0;min-width:0}fieldset:disabled{opacity:.65}.form-stack>p{line-height:1.6}</style>
