<script setup lang="ts">
import { computed, ref } from "vue";
import { useRoute } from "vue-router";
import type { Settings } from "../domain";
import { secretsOf } from "../domain";
import AppIcon from "../components/AppIcon.vue";
import { createAppHttp } from "../protocol/http";
import { listModels } from "../protocol/models";
import { redactSecrets } from "../protocol/redact";
import { useLibraryStore } from "../stores/library";
import { useLogStore } from "../stores/logs";
import { useSettingsStore } from "../stores/settings";
import { useWorkspaceStore } from "../stores/workspace";
import AppearanceSettings from "../components/AppearanceSettings.vue";
import SpeechSettings from "../components/SpeechSettings.vue";
import RegexEditor from "../components/RegexEditor.vue";
const settings = useSettingsStore();
const library = useLibraryStore();
const logs = useLogStore();
const workspace = useWorkspaceStore();
const route = useRoute();
const titles: Record<string, string> = {
  connection: "服务器与模型",
  logs: "日志通道",
  profile: "身份与日记",
  appearance: "外观",
  render: "高级渲染",
  data: "本机数据",
  about: "关于 VCPChat",
  speech: "语音与朗读",
  regex: "全局正则",
};
const section = computed(() =>
  typeof route.params.section === "string" && titles[route.params.section]
    ? route.params.section
    : "",
);
const showKey = ref(false);
const modelStatus = ref("");
const checking = ref(false);
const models = ref<string[]>([]);
const globalRules = computed({ get: () => settings.settings.regexRules, set: (regexRules) => { void settings.patch({ regexRules }); } });
const renderSwitches = [
  { key: "renderCode", label: "代码高亮", description: "代码块的语法着色" },
  { key: "renderMath", label: "KaTeX 公式", description: "数学公式与符号" },
  {
    key: "renderMermaid",
    label: "Mermaid 图表",
    description: "流程图、时序图等",
  },
  {
    key: "renderHtml",
    label: "HTML 气泡",
    description: "在独立沙箱里运行动画与交互",
  },
  {
    key: "renderMedia",
    label: "图片与视频预览",
    description: "点击图片放大，播放视频",
  },
  {
    key: "renderMotion",
    label: "气泡动画",
    description: "消息出现与生成时的轻动效",
  },
] as const satisfies readonly {
  key: keyof Settings;
  label: string;
  description: string;
}[];
async function refreshModels() {
  checking.value = true;
  modelStatus.value = "正在连接…";
  try {
    const http = await createAppHttp();
    models.value = await listModels(settings.settings, http);
    if (!settings.settings.defaultModel)
      await settings.patch({ defaultModel: models.value[0] });
    modelStatus.value = `连接成功 · ${models.value.length} 个模型`;
  } catch (error) {
    modelStatus.value = redactSecrets(
      error instanceof Error ? error.message : String(error),
      secretsOf(settings.settings),
    );
  } finally {
    checking.value = false;
  }
}
async function connectLogs() {
  await logs.reconnect();
}
async function clearHistory() {
  if (confirm("清除这台设备上的全部会话和消息？Agent 和设置会留下。"))
    await library.clearHistory();
}
async function clearKeys() {
  if (confirm("清除本机保存的 API Key、日志密钥与管理员密码？"))
    await settings.clearSecrets();
}
</script>
<template>
  <section class="page settings-page">
    <header class="page-header" :class="{ 'detail-header': section }">
      <RouterLink
        v-if="section"
        to="/settings"
        class="icon-button"
        aria-label="返回设置"
      ><AppIcon name="back" /></RouterLink>
      <div>
        <p v-if="!section" class="eyebrow">让一切顺手</p>
        <h1>{{ section ? titles[section] : "设置" }}</h1>
      </div>
      <span v-if="section && section !== 'about'" class="header-note">本机保存</span>
    </header>
    <div class="page-scroll settings-content">
      <template v-if="!section">
        <div class="settings-intro">
          <div class="app-mark"><AppIcon name="render" :size="30" /></div>
          <div><strong>VCPChat</strong><span>你的 Agent，随身同行。</span></div>
          <span class="version-label">0.2.1</span>
        </div>
        <h2 class="settings-label">连接</h2>
        <div class="settings-group">
          <RouterLink to="/settings/connection" class="settings-row"><span class="setting-icon"><AppIcon name="server" /></span><span><strong>服务器与模型</strong><small>{{
            settings.settings.defaultModel || "连接你的 VCPToolBox"
          }}</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/settings/logs" class="settings-row"><span class="setting-icon blue"><AppIcon name="logs" /></span><span><strong>日志通道</strong><small>VCPLog 与 VCPInfo</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/logs" class="settings-row"><span class="setting-icon blue"><AppIcon name="history" /></span><span><strong>查看实时日志</strong><small>{{ logs.status.log }}</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
        </div>
        <h2 class="settings-label">个性化</h2>
        <div class="settings-group">
          <button
            class="settings-row"
            type="button"
            @click="workspace.open({ type: 'main-agent' })"
          >
            <span class="setting-icon"><AppIcon name="star" /></span><span><strong>主 Agent</strong><small>{{ library.mainAgent?.name }}</small></span><AppIcon name="chevron" :size="18" />
          </button>
          <label class="settings-row"><span class="setting-icon blue"><AppIcon name="keyboard" /></span><span><strong>Enter 发送消息</strong><small>{{ settings.settings.enterSends ? 'Shift+Enter 换行' : 'Enter 换行；⌘/Ctrl+Enter 发送' }}</small></span><input type="checkbox" role="switch" aria-label="Enter 发送消息" :checked="settings.settings.enterSends" @change="settings.patch({ enterSends: !settings.settings.enterSends })" /></label>
          <RouterLink to="/settings/render" class="settings-row"><span class="setting-icon purple"><AppIcon name="render" /></span><span><strong>高级渲染</strong><small>{{
            settings.settings.richRender ? "已开启" : "轻量模式"
          }}</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/settings/appearance" class="settings-row"><span class="setting-icon purple"><AppIcon name="palette" /></span><span><strong>外观</strong><small>{{
            { ink: "深色", paper: "浅色", aurora: "极光" }[
              settings.settings.theme
            ]
          }}</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/settings/profile" class="settings-row"><span class="setting-icon blue"><AppIcon name="agents" /></span><span><strong>身份与日记</strong><small>称呼与服务器日记账号</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/settings/speech" class="settings-row"><span class="setting-icon"><AppIcon name="speaker" /></span><span><strong>语音与朗读</strong><small>SoVITS / MiMo · 每个 Agent 的声音</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
          <RouterLink to="/settings/regex" class="settings-row"><span class="setting-icon purple"><AppIcon name="regex" /></span><span><strong>全局正则</strong><small>{{ settings.settings.regexRules.length }} 条规则 · 显示与上下文</small></span><AppIcon name="chevron" :size="18" /></RouterLink>
        </div>
        <h2 class="settings-label">应用</h2>
        <div class="settings-group">
          <RouterLink to="/settings/data" class="settings-row"><span class="setting-icon"><AppIcon name="shield" /></span><span><strong>本机数据</strong></span><AppIcon name="chevron" :size="18" /></RouterLink><RouterLink to="/settings/about" class="settings-row"><span class="setting-icon"><AppIcon name="chat" /></span><span><strong>关于 VCPChat</strong></span><AppIcon name="chevron" :size="18" /></RouterLink>
        </div>
      </template>
      <form
        v-else-if="section === 'connection'"
        class="form-stack"
        @submit.prevent="refreshModels"
      >
        <div class="card">
          <label class="field">VCP 服务器 URL<input
            v-model="settings.settings.serverUrl"
            type="url"
            inputmode="url"
            placeholder="http://192.168.1.8:6005"
            autocomplete="off"
            autocapitalize="none"
            @change="
              settings.patch({ serverUrl: settings.settings.serverUrl })
            "
          /></label>
          <p class="hint">可填写主机地址，或完整的 API 路径。</p>
          <label class="field">API Key<input
            v-model="settings.settings.apiKey"
            :type="showKey ? 'text' : 'password'"
            autocomplete="off"
            autocapitalize="none"
            @change="
              settings.patch({ apiKey: settings.settings.apiKey })
            "
          /></label><label class="check"><input v-model="showKey" type="checkbox" />显示密钥</label>
        </div>
        <div class="card">
          <label class="field">接口<select
            v-model="settings.settings.endpointMode"
            @change="
              settings.patch({ endpointMode: settings.settings.endpointMode })
            "
          >
            <option value="standard">OpenAI 兼容</option>
            <option value="vcp-tools">VCP 工具模式</option>
          </select></label><label class="field">默认模型<input
            v-model="settings.settings.defaultModel"
            type="text"
            list="model-options"
            placeholder="刷新模型后选择，或手动填写"
            @change="
              settings.patch({ defaultModel: settings.settings.defaultModel })
            "
          /></label><datalist id="model-options">
            <option
              v-for="model in models"
              :key="model"
              :value="model"
            />
          </datalist><label class="switch-row"><span><strong>发送 Temperature</strong><small>部分模型不接受此参数</small></span><input
            :checked="settings.settings.sendTemperature"
            type="checkbox"
            role="switch"
            @change="
              settings.patch({
                sendTemperature: !settings.settings.sendTemperature,
              })
            "
          /></label><label v-if="settings.settings.sendTemperature" class="field">Temperature<input
            v-model.number="settings.settings.temperature"
            type="number"
            min="0"
            max="2"
            step="0.1"
            @change="
              settings.patch({ temperature: settings.settings.temperature })
            "
          /></label>
        </div>
        <button class="primary wide-button" type="submit" :disabled="checking">
          {{ checking ? "正在连接…" : "测试连接并刷新模型" }}
        </button>
        <p class="form-status" aria-live="polite">{{ modelStatus }}</p>
      </form>
      <form
        v-else-if="section === 'logs'"
        class="form-stack"
        @submit.prevent="connectLogs"
      >
        <div class="card">
          <label class="field">VCP WebSocket URL<input
            v-model="settings.settings.logUrl"
            type="url"
            inputmode="url"
            placeholder="ws://192.168.1.8:6005"
            autocapitalize="none"
            autocomplete="off"
            @change="
              settings.patch({ logUrl: settings.settings.logUrl })
            "
          /></label><label class="field">VCP WebSocket Key<input
            v-model="settings.settings.logKey"
            :type="showKey ? 'text' : 'password'"
            autocomplete="off"
            @change="
              settings.patch({ logKey: settings.settings.logKey })
            "
          /></label><label class="check"><input v-model="showKey" type="checkbox" />显示密钥</label>
        </div>
        <button class="primary wide-button" type="submit">连接日志通道</button>
        <div class="connection-status">
          <span><i :class="{ connected: logs.status.log === '已连接' }" />VCPLog ·
            {{ logs.status.log }}</span><span><i :class="{ connected: logs.status.info === '已连接' }" />VCPInfo
            · {{ logs.status.info }}</span>
        </div>
        <RouterLink class="setting-action" to="/logs"><AppIcon name="logs" />查看实时日志<AppIcon
          name="chevron"
          :size="18"
        /></RouterLink>
      </form>
      <form
        v-else-if="section === 'profile'"
        class="form-stack"
        @submit.prevent
      >
        <div class="card">
          <label class="field">你的名字<input
            v-model="settings.settings.userName"
            type="text"
            placeholder="Agent 怎么称呼你"
            @change="
              settings.patch({ userName: settings.settings.userName })
            "
          /></label>
        </div>
        <h2 class="settings-label">服务器日记</h2>
        <div class="card">
          <label class="field">管理员用户名<input
            v-model="settings.settings.adminUsername"
            type="text"
            autocomplete="off"
            @change="
              settings.patch({
                adminUsername: settings.settings.adminUsername,
              })
            "
          /></label><label class="field">管理员密码<input
            v-model="settings.settings.adminPassword"
            type="password"
            autocomplete="off"
            @change="
              settings.patch({
                adminPassword: settings.settings.adminPassword,
              })
            "
          /></label>
        </div>
        <p class="section-note">只用于服务器日记；聊天使用单独的 API Key。</p>
      </form>
      <AppearanceSettings v-else-if="section === 'appearance'" />
      <SpeechSettings v-else-if="section === 'speech'" />
      <RegexEditor v-else-if="section === 'regex'" v-model="globalRules" />
      <div v-else-if="section === 'render'" class="form-stack">
        <div class="settings-group">
          <label class="switch-row master-switch"><span><strong>开启高级渲染</strong><small>切换后，已有消息立即更新</small></span><input
            :checked="settings.settings.richRender"
            type="checkbox"
            role="switch"
            @change="
              settings.patch({ richRender: !settings.settings.richRender })
            "
          /></label>
        </div>
        <fieldset
          class="settings-group render-switches"
          :disabled="!settings.settings.richRender"
        >
          <legend class="sr-only">渲染选项</legend>
          <label
            v-for="item in renderSwitches"
            :key="item.key"
            class="switch-row"
          ><span><strong>{{ item.label }}</strong><small>{{ item.description }}</small></span><input
            :checked="settings.settings[item.key]"
            type="checkbox"
            role="switch"
            @change="
              settings.patch({ [item.key]: !settings.settings[item.key] })
            "
          /></label>
        </fieldset>
        <p class="section-note">
          关闭总开关后使用轻量 Markdown，HTML 不运行；工具与日记卡片仍保留。
        </p>
      </div>
      <div v-else-if="section === 'data'" class="form-stack">
        <div class="card">
          <AppIcon name="shield" :size="30" />
          <h2>你的数据，留在本机</h2>
          <p class="hint">
            会话、笔记和设置存储在这台设备的 IndexedDB 中，没有内置云同步。
          </p>
        </div>
        <div class="settings-group">
          <button
            class="setting-action danger"
            type="button"
            @click="clearKeys"
          >
            清除密钥
          </button><button
            class="setting-action danger"
            type="button"
            @click="clearHistory"
          >
            清除全部会话
          </button>
        </div>
      </div>
      <div v-else-if="section === 'about'" class="about-app">
        <div class="app-mark"><AppIcon name="render" :size="36" /></div>
        <h2>VCPChat</h2>
        <p class="hint">0.2.1 · 随身的 Agent 工作空间</p>
        <div class="card">
          <p>
            连接你自己的 VCPToolBox。界面与协议分层参考
            <a
              href="https://github.com/MRiecy/VCPMobile"
              target="_blank"
              rel="noreferrer"
            >MRiecy / VCPMobile</a>，桌面行为参考
            <a
              href="https://github.com/lioensky/VCPChat"
              target="_blank"
              rel="noreferrer"
            >lioensky / VCPChat</a>。两者均为 CC BY-NC-SA 4.0，本仓库同样以此许可发布，并作了改动。
          </p>
        </div>
      </div>
    </div>
  </section>
</template>
