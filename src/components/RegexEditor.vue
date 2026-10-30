<script setup lang="ts">
import { computed, ref } from "vue";
import type { RegexRule } from "../domain";
import { compileRule, importRules } from "../protocol/regex";
import { createId } from "../protocol/ids";
import AppIcon from "./AppIcon.vue";
const rules = defineModel<RegexRule[]>({ required: true });
const edit = ref<RegexRule | null>(null); const error = ref(""); const sample = ref("你好，{{user}}。\n这里是一段用于测试的文字。");
const preview = computed(() => { if (!edit.value?.findPattern) return sample.value; try { return sample.value.replace(compileRule(edit.value.findPattern), edit.value.replaceWith); } catch { return "表达式尚未有效"; } });
function start(rule?: RegexRule) { edit.value = rule ? { ...rule, applyToRoles: [...rule.applyToRoles] } : { id: createId("rule"), title: "", findPattern: "", replaceWith: "", applyToRoles: ["assistant"], applyToFrontend: true, applyToContext: false, minDepth: 0, maxDepth: -1, enabled: true }; error.value = ""; }
function save() {
  if (!edit.value) return;
  try {
    if (!edit.value.title.trim() || !edit.value.findPattern) throw new Error("填写规则名称和查找表达式");
    compileRule(edit.value.findPattern);
    if (!edit.value.applyToRoles.length || !edit.value.applyToFrontend && !edit.value.applyToContext) throw new Error("至少选择一种角色和一个作用范围");
    const next = { ...edit.value, title: edit.value.title.trim() };
    rules.value = rules.value.some((r) => r.id === next.id) ? rules.value.map((r) => r.id === next.id ? next : r) : [...rules.value, next]; edit.value = null; error.value = "";
  } catch (caught) { error.value = caught instanceof Error ? caught.message : "表达式无效"; }
}
function toggle(rule: RegexRule) { rules.value = rules.value.map((r) => r.id === rule.id ? { ...r, enabled: !r.enabled } : r); }
function move(index: number, delta: number) { const copy = [...rules.value]; const other = index + delta; if (other < 0 || other >= copy.length) return; [copy[index], copy[other]] = [copy[other], copy[index]]; rules.value = copy; }
async function importFile(event: Event) {
  const input = event.target as HTMLInputElement; const file = input.files?.[0]; input.value = ""; if (!file) return;
  try { if (file.size > 500_000) throw new Error("正则文件不能超过 500KB"); rules.value = [...rules.value, ...importRules(JSON.parse(await file.text()))]; error.value = ""; }
  catch (caught) { error.value = caught instanceof Error ? caught.message : "正则文件没有读出来"; }
}
function remove(rule: RegexRule) { if (confirm(`删除正则「${rule.title}」？`)) rules.value = rules.value.filter((r) => r.id !== rule.id); }
function exportRule(rule: RegexRule) { const url = URL.createObjectURL(new Blob([JSON.stringify(rule, null, 2)], { type: "application/json" })); const link = document.createElement("a"); link.href = url; link.download = `${rule.title.replace(/[/\\]/g, "_")}.json`; link.click(); URL.revokeObjectURL(url); }
</script>
<template>
  <div class="regex-editor">
    <template v-if="!edit">
      <div class="regex-toolbar"><button class="ghost" type="button" @click="start()"><AppIcon name="plus" :size="17" />新建规则</button><label class="ghost file-action"><AppIcon name="upload" :size="17" />导入 JSON<input class="sr-only" type="file" accept="application/json,.json" aria-label="导入 VChat 或 SillyTavern 正则" @change="importFile" /></label></div>
      <p class="section-note">按顺序应用，支持 VChat 和 SillyTavern 格式。</p>
      <div v-for="(rule, index) in rules" :key="rule.id" class="regex-rule-row"><button class="regex-rule-open" type="button" @click="start(rule)"><span class="setting-icon purple"><AppIcon name="regex" :size="20" /></span><span><strong>{{ rule.title }}</strong><small>{{ rule.applyToFrontend ? '显示' : '' }}{{ rule.applyToFrontend && rule.applyToContext ? ' + ' : '' }}{{ rule.applyToContext ? '上下文' : '' }} · {{ rule.applyToRoles.map((role) => role === 'assistant' ? 'Agent' : '用户').join(' / ') }}</small></span></button><input type="checkbox" role="switch" :checked="rule.enabled" :aria-label="`启用正则 ${rule.title}`" @change="toggle(rule)" /><div class="regex-row-actions"><button class="text-button" type="button" :disabled="index === 0" :aria-label="`上移 ${rule.title}`" @click="move(index, -1)"><AppIcon name="up" :size="17" /></button><button class="text-button" type="button" :disabled="index === rules.length - 1" :aria-label="`下移 ${rule.title}`" @click="move(index, 1)"><AppIcon name="down" :size="17" /></button><button class="text-button" type="button" :aria-label="`导出 ${rule.title}`" @click="exportRule(rule)"><AppIcon name="download" :size="15" /></button><button class="text-button danger" type="button" :aria-label="`删除正则 ${rule.title}`" @click="remove(rule)"><AppIcon name="trash" :size="15" /></button></div></div>
      <div v-if="!rules.length" class="empty compact"><AppIcon name="regex" :size="32" /><h3>按你的习惯整理文本</h3><p>替换称呼、清理标记，或接入已有渲染规则。</p></div>
    </template>
    <div v-else class="stack regex-rule-form">
      <button class="text-button regex-back" type="button" @click="edit = null"><AppIcon name="back" :size="16" />返回规则列表</button>
      <label class="field">规则名称<input v-model="edit.title" type="text" placeholder="例如：替换用户称呼" /></label><label class="field">查找表达式<textarea v-model="edit.findPattern" rows="2" autocapitalize="none" spellcheck="false" placeholder="/pattern/g" /></label><label class="field">替换为<textarea v-model="edit.replaceWith" rows="3" spellcheck="false" placeholder="支持 $1、$2 等捕获组；留空为删除" /></label>
      <fieldset class="regex-scope"><legend>应用角色</legend><label class="check"><input v-model="edit.applyToRoles" type="checkbox" value="user" />用户消息</label><label class="check"><input v-model="edit.applyToRoles" type="checkbox" value="assistant" />Agent 回复</label></fieldset>
      <fieldset class="regex-scope"><legend>作用范围</legend><label class="check"><input v-model="edit.applyToFrontend" type="checkbox" />显示的消息</label><label class="check"><input v-model="edit.applyToContext" type="checkbox" />发给模型的上下文</label></fieldset><p class="hint">上下文规则只改变发送副本，保存的原文不变。</p>
      <div class="two-columns"><label class="field">最小回合深度<input v-model.number="edit.minDepth" type="number" min="-1" /></label><label class="field">最大回合深度<input v-model.number="edit.maxDepth" type="number" min="-1" /></label></div><p class="hint">0 是最近一轮，-1 为不限。</p>
      <details class="regex-preview" open><summary>试一试</summary><label class="field">测试原文<textarea v-model="sample" rows="3" /></label><label class="field">替换结果<textarea :value="preview" rows="3" readonly /></label></details><div class="row"><button class="ghost" type="button" @click="edit = null">取消</button><button class="primary" type="button" @click="save">保存规则</button></div>
    </div>
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
  </div>
</template>
