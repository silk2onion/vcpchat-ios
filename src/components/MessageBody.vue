<script setup lang="ts">
import { computed } from "vue";
import { parseMarkdown } from "../protocol/markdown";
import { parseSegments, type Segment } from "../protocol/tools";
import { splitHtmlIslands, type Island } from "../render/html";
import { isSafeMediaUrl, openViewer } from "../render/media";
import { effectiveOptions, fullRenderOptions, type RenderOptions } from "../render/options";
import RichMarkdown from "./RichMarkdown.vue";
import SandboxFrame from "./SandboxFrame.vue";

const props = defineProps<{
  content: string;
  reasoning: string;
  streaming?: boolean;
  options?: RenderOptions;
}>();

const options = computed(() => effectiveOptions(props.options ?? fullRenderOptions()));
const segments = computed(() => parseSegments(props.content));
const roleLabels = { system: "System", assistant: "Assistant", user: "User" } as const;

function islands(segment: Segment & { type: "text" }): Island[] {
  if (!options.value.html) return [{ type: "markdown", text: segment.text }];
  return splitHtmlIslands(segment.text, Boolean(props.streaming));
}

function sandboxHtml(island: Island & { type: "html" }): string {
  return island.document ? island.html : parseMarkdown(island.html);
}

function isLast(index: number): boolean {
  return index === segments.value.length - 1;
}

function imageField(value: string): string {
  const url = value.trim();
  return /^https?:\/\/\S+\.(?:png|jpe?g|gif|webp|avif)(?:[?#]\S*)?$/i.test(url) && isSafeMediaUrl(url) ? url : "";
}
</script>

<template>
  <details v-if="reasoning" class="think" :open="streaming">
    <summary>思考</summary>
    <RichMarkdown class="think-body" :source="reasoning" :options="options" :streaming="streaming" safe />
  </details>
  <template v-for="(segment, index) in segments" :key="index">
    <template v-if="segment.type === 'text'">
      <template v-for="(island, part) in islands(segment)" :key="`${index}-${part}`">
        <RichMarkdown
          v-if="island.type === 'markdown'"
          :source="island.text"
          :options="options"
          :streaming="streaming"
          :caret="streaming && isLast(index)"
        />
        <SandboxFrame v-else-if="island.closed" :html="sandboxHtml(island)" />
        <p v-else class="html-pending">HTML 气泡生成中，写完后在沙箱里运行</p>
      </template>
    </template>
    <details v-else-if="segment.type === 'think'" class="think" :open="!segment.closed">
      <summary>{{ segment.title || "思考过程" }}{{ segment.closed ? "" : " · 进行中" }}</summary>
      <RichMarkdown class="think-body" :source="segment.text" :options="options" :streaming="!segment.closed" safe />
    </details>
    <details v-else-if="segment.type === 'tool'" class="tool" :open="!segment.closed">
      <summary>{{ segment.closed ? "工具" : "工具 · 输入中" }} · {{ segment.name }}<span v-if="segment.command"> · {{ segment.command }}</span></summary>
      <pre>{{ segment.body }}</pre>
    </details>
    <section v-else-if="segment.type === 'diary'" class="diary" :class="segment.entry.mode">
      <header class="diary-head">
        <strong>{{ segment.entry.mode === "update" ? "日记修改" : segment.entry.title }}</strong>
        <span v-if="segment.entry.date" class="meta">{{ segment.entry.date }}</span>
        <span v-if="!segment.closed" class="meta">写入中</span>
      </header>
      <p v-if="segment.entry.agent || segment.entry.folder" class="hint">
        <template v-if="segment.entry.agent">{{ segment.entry.agentLabel }}：{{ segment.entry.agent }}</template>
        <template v-if="segment.entry.agent && segment.entry.folder"> · </template>
        <template v-if="segment.entry.folder">文件夹：{{ segment.entry.folder }}</template>
      </p>
      <div v-if="segment.entry.mode === 'update'" class="diary-diff">
        <div>
          <span class="eyebrow">原文</span>
          <RichMarkdown :source="segment.entry.target || '（原文没有解析出来）'" :options="options" :streaming="!segment.closed" safe />
        </div>
        <span class="diary-arrow" aria-hidden="true">→</span>
        <div>
          <span class="eyebrow">改为</span>
          <RichMarkdown :source="segment.entry.replace || '（新内容没有解析出来）'" :options="options" :streaming="!segment.closed" safe />
        </div>
      </div>
      <RichMarkdown v-else :source="segment.entry.content || '（日记内容没有解析出来）'" :options="options" :streaming="!segment.closed" safe />
      <p v-if="segment.entry.tag" class="hint">Tag：{{ segment.entry.tag }}</p>
    </section>
    <details v-else-if="segment.type === 'result'" class="result" :class="{ failed: segment.ok === false }" :open="!segment.closed">
      <summary>
        {{ segment.closed ? "工具结果" : "工具结果 · 接收中" }}<span v-if="segment.toolName"> · {{ segment.toolName }}</span>
        <span v-if="segment.status" class="result-status">{{ segment.status }}</span>
      </summary>
      <div class="result-body">
        <dl v-if="segment.fields.length" class="result-fields">
          <template v-for="field in segment.fields" :key="field.key">
            <dt>{{ field.key }}</dt>
            <dd>
              <img v-if="options.media && imageField(field.value)" class="media-thumb" :src="imageField(field.value)" :alt="field.key" loading="lazy" @click="openViewer({ kind: 'image', src: imageField(field.value), alt: field.key })" />
              <template v-else>{{ field.value }}</template>
            </dd>
          </template>
        </dl>
        <RichMarkdown v-if="segment.content" :source="segment.content" :options="options" :streaming="!segment.closed" safe />
      </div>
    </details>
    <section v-else-if="segment.type === 'summary'" class="tool-summary">
      <span class="eyebrow">本轮工具调用</span>
      <span v-for="(item, chip) in segment.items" :key="chip" class="chip">{{ item }}</span>
    </section>
    <div v-else-if="segment.type === 'divider'" class="role-divider" :class="segment.role">
      <span>{{ roleLabels[segment.role] }} 分界之{{ segment.end ? "末" : "始" }}</span>
    </div>
    <details v-else class="tool push">
      <summary>桌面推送{{ segment.closed ? "" : " · 接收中" }} · 只在桌面端展示</summary>
      <pre>{{ segment.text }}</pre>
    </details>
  </template>
  <span v-if="streaming && !content" class="caret" />
</template>
