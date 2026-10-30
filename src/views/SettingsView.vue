<script setup lang="ts">
import { ref } from "vue";
import type { Settings } from "../domain";
import { createAppHttp } from "../protocol/http";
import { listModels } from "../protocol/models";
import { useLibraryStore } from "../stores/library";
import { useLogStore } from "../stores/logs";
import { useSettingsStore } from "../stores/settings";

const settings = useSettingsStore();
const library = useLibraryStore();
const logs = useLogStore();
const showKey = ref(false);
const modelStatus = ref("");
const models = ref<string[]>([]);
const renderSwitches = [
  { key: "renderCode", label: "代码高亮" },
  { key: "renderMath", label: "KaTeX 公式" },
  { key: "renderMermaid", label: "Mermaid 图表" },
  { key: "renderHtml", label: "HTML 气泡（沙箱运行）" },
  { key: "renderMedia", label: "图片与视频预览" },
  { key: "renderMotion", label: "气泡动画" },
] as const satisfies readonly { key: keyof Settings; label: string }[];

async function refreshModels() {
  modelStatus.value = "正在询问 /v1/models";
  try {
    const http = await createAppHttp();
    models.value = await listModels(settings.settings, http);
    if (!settings.settings.defaultModel) await settings.patch({ defaultModel: models.value[0] });
    modelStatus.value = `拿到 ${models.value.length} 个模型`;
  } catch (error) {
    modelStatus.value = error instanceof Error ? error.message : "模型列表失败";
  }
}

async function onLogChange() {
  await logs.sync();
}

async function clearHistory() {
  if (confirm("清除这台设备上的全部话题和消息？助手和设置会留下。")) await library.clearHistory();
}
</script>

<template>
  <section class="screen">
    <header>
      <p class="eyebrow">连接</p>
      <h1>设置</h1>
    </header>
    <p v-if="settings.status" class="ok-line">{{ settings.status }}</p>
    <form class="card" @submit.prevent="refreshModels">
      <h2>服务器</h2>
      <label class="field">VCP 服务器 URL
        <input v-model="settings.settings.serverUrl" type="url" placeholder="http://192.168.1.8:6005" autocomplete="off" @change="settings.patch({ serverUrl: settings.settings.serverUrl })" />
      </label>
      <p class="hint">可以写到主机端口，也可以写到 /v1 或 /v1/chat/completions。不会把密钥放进地址。</p>
      <label class="field">API Key
        <input v-model="settings.settings.apiKey" :type="showKey ? 'text' : 'password'" autocomplete="off" @change="settings.patch({ apiKey: settings.settings.apiKey })" />
      </label>
      <label class="check"><input v-model="showKey" type="checkbox" /> 显示密钥</label>
      <label class="field">接口
        <select v-model="settings.settings.endpointMode" @change="settings.patch({ endpointMode: settings.settings.endpointMode })">
          <option value="standard">OpenAI 兼容 /v1/chat/completions</option>
          <option value="vcp-tools">VCP 工具 /v1/chatvcp/completions</option>
        </select>
      </label>
      <label class="field">默认模型
        <input v-model="settings.settings.defaultModel" type="text" list="model-options" placeholder="先刷新模型列表，或自己填写" @change="settings.patch({ defaultModel: settings.settings.defaultModel })" />
      </label>
      <datalist id="model-options">
        <option v-for="model in models" :key="model" :value="model" />
      </datalist>
      <label class="check">
        <input :checked="settings.settings.sendTemperature" type="checkbox" @change="settings.patch({ sendTemperature: !settings.settings.sendTemperature })" />
        发送 temperature
      </label>
      <label v-if="settings.settings.sendTemperature" class="field">temperature
        <input v-model.number="settings.settings.temperature" type="number" min="0" max="2" step="0.1" @change="settings.patch({ temperature: settings.settings.temperature })" />
      </label>
      <div class="row">
        <button class="primary" type="submit">测试并刷新模型</button>
        <span class="hint">{{ modelStatus }}</span>
      </div>
    </form>
    <form class="card" @submit.prevent="onLogChange">
      <h2>WebSocket</h2>
      <label class="field">VCP WebSocket URL
        <input v-model="settings.settings.logUrl" type="url" placeholder="ws://192.168.1.8:6005" autocomplete="off" @change="settings.patch({ logUrl: settings.settings.logUrl }).then(onLogChange)" />
      </label>
      <label class="field">VCP WebSocket Key
        <input v-model="settings.settings.logKey" :type="showKey ? 'text' : 'password'" autocomplete="off" @change="settings.patch({ logKey: settings.settings.logKey }).then(onLogChange)" />
      </label>
      <button class="ghost" type="submit">连接日志通道</button>
    </form>
    <form class="card">
      <h2>身份与日记</h2>
      <label class="field">你的名字
        <input v-model="settings.settings.userName" type="text" placeholder="会放进系统提示" @change="settings.patch({ userName: settings.settings.userName })" />
      </label>
      <label class="field">管理员用户名
        <input v-model="settings.settings.adminUsername" type="text" autocomplete="off" @change="settings.patch({ adminUsername: settings.settings.adminUsername })" />
      </label>
      <label class="field">管理员密码
        <input v-model="settings.settings.adminPassword" type="password" autocomplete="off" @change="settings.patch({ adminPassword: settings.settings.adminPassword })" />
      </label>
      <p class="hint">只有服务器日记需要管理员账号。聊天本身只使用 API Key。</p>
    </form>
    <form class="card">
      <h2>外观</h2>
      <div class="segmented">
        <button type="button" :aria-pressed="settings.settings.theme === 'ink'" @click="settings.patch({ theme: 'ink' })">墨色</button>
        <button type="button" :aria-pressed="settings.settings.theme === 'paper'" @click="settings.patch({ theme: 'paper' })">纸色</button>
        <button type="button" :aria-pressed="settings.settings.theme === 'aurora'" @click="settings.patch({ theme: 'aurora' })">极光</button>
      </div>
    </form>
    <form class="card">
      <h2>高级渲染</h2>
      <label class="check">
        <input :checked="settings.settings.richRender" type="checkbox" @change="settings.patch({ richRender: !settings.settings.richRender })" />
        开启高级渲染
      </label>
      <p class="hint">关掉更省电：消息只渲染轻量 Markdown，不加载高亮、公式和图表库，HTML 不运行，也没有动画。工具卡片和日记卡片照常显示。切换后已有消息会重新渲染。</p>
      <fieldset class="sub-switches" :disabled="!settings.settings.richRender">
        <label v-for="item in renderSwitches" :key="item.key" class="check">
          <input :checked="settings.settings[item.key]" type="checkbox" @change="settings.patch({ [item.key]: !settings.settings[item.key] })" />
          {{ item.label }}
        </label>
      </fieldset>
    </form>
    <div class="card">
      <h2>本机数据</h2>
      <div class="row">
        <button class="danger" type="button" @click="settings.clearSecrets()">清除密钥</button>
        <button class="danger" type="button" @click="clearHistory">清除对话</button>
      </div>
      <p class="hint">对话、笔记和设置保存在这台设备的 IndexedDB 里。没有内置云同步。</p>
    </div>
    <div class="card">
      <h2>关于</h2>
      <p>VCPChat iOS 是连接你自己的 VCPToolBox 的手机客户端。界面和协议分层参考 <a href="https://github.com/MRiecy/VCPMobile" target="_blank" rel="noreferrer">MRiecy / VCPMobile</a>，桌面行为参考 <a href="https://github.com/lioensky/VCPChat" target="_blank" rel="noreferrer">lioensky / VCPChat</a>。两者均为 CC BY-NC-SA 4.0，本仓库同样以此许可发布，并作了改动。</p>
      <p class="hint">不会在代码或构建产物里写入任何密钥。</p>
    </div>
  </section>
</template>
