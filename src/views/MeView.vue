<script setup lang="ts">
import ProfileAvatar from "../components/ProfileAvatar.vue";
import AppIcon from "../components/AppIcon.vue";
import { useSettingsStore } from "../stores/settings";
import { useNotesStore } from "../stores/notes";
import { useLogStore } from "../stores/logs";
import { useWorkspaceStore } from "../stores/workspace";
const settings = useSettingsStore();
const notes = useNotesStore();
const logs = useLogStore();
const workspace = useWorkspaceStore();
</script>
<template>
  <section class="page me-page">
    <header class="page-header"><h1>我</h1></header>
    <div class="page-scroll me-content">
      <div class="me-profile">
        <ProfileAvatar compact />
        <RouterLink to="/settings/profile?from=me" class="me-profile-link">
          <span><strong>{{ settings.settings.userName || '设置你的名字' }}</strong><small>个人资料与日记身份</small></span>
          <AppIcon name="chevron" :size="20" />
        </RouterLink>
      </div>
      <div class="settings-group">
        <RouterLink to="/sync" class="settings-row"><span class="setting-icon"><AppIcon name="sync" /></span><span><strong>桌面同步</strong><small>会话、Agent 与群组</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
        <RouterLink to="/files" class="settings-row"><span class="setting-icon blue"><AppIcon name="folder" /></span><span><strong>文件</strong><small>连接文件夹、本机与服务器</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
        <RouterLink to="/notes" class="settings-row"><span class="setting-icon blue"><AppIcon name="notes" /></span><span><strong>笔记</strong><small>本机笔记与服务器日记</small></span><span v-if="notes.notes.length" class="me-count">{{ notes.notes.length }}</span><AppIcon name="chevron" :size="18" /></RouterLink>
        <button type="button" class="settings-row" @click="workspace.openActivity()"><span class="setting-icon purple"><AppIcon name="bell" /></span><span><strong>通知中心</strong><small>待审批、VCPLog 与 RAG</small></span><span v-if="logs.unread" class="me-unread">{{ logs.unread > 99 ? '99+' : logs.unread }}</span><AppIcon name="chevron" :size="18" /></button>
      </div>
      <div class="settings-group">
        <RouterLink to="/settings" class="settings-row"><span class="setting-icon"><AppIcon name="settings" /></span><span><strong>设置</strong><small>连接、外观与使用习惯</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
      </div>
    </div>
  </section>
</template>
<style scoped>
.me-content{display:flex;flex-direction:column;gap:22px}.me-profile{display:flex;align-items:center;gap:17px;padding:24px 4px 28px;color:var(--ink);min-width:0}.me-profile-link{display:flex;align-items:center;gap:14px;flex:1;min-width:0;color:inherit}.me-profile-link>span{flex:1;min-width:0}.me-profile strong{display:block;font-size:24px;line-height:1.4;overflow-wrap:anywhere}.me-profile small{display:block;color:var(--muted);font-size:13px;line-height:1.5;margin-top:7px}.me-profile-link>svg{color:var(--muted);flex-shrink:0}.me-count{color:var(--muted);font-size:13px}.me-unread{background:var(--danger);color:white;border-radius:12px;min-width:20px;padding:3px 6px;text-align:center;font-size:11px}
</style>
