<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, useId, watch } from "vue";
import { useModelStore } from "../stores/models";
import AppIcon from "./AppIcon.vue";
withDefaults(defineProps<{ label: string; placeholder?: string; inherit?: boolean; inheritedModel?: string }>(), { placeholder: "选择模型，或手动填写 ID", inherit: false, inheritedModel: "" });
const value = defineModel<string>({ required: true });
const emit = defineEmits<{ commit: [value: string] }>();
const models = useModelStore();
const root = ref<HTMLElement | null>(null); const search = ref<HTMLInputElement | null>(null); const scroller = ref<HTMLElement | null>(null); const trigger = ref<HTMLButtonElement | null>(null);
const open = ref(false); const query = ref(""); const active = ref(0); const top = ref(0);
const id = useId(); const listId = `models-${id}`; const fieldId = `model-input-${id}`;
const ROW = 52; const OVERSCAN = 3;
const viewportHeight = ref(844);
function resize() { viewportHeight.value = window.visualViewport?.height ?? window.innerHeight; }
const indexed = computed(() => {
  const recent = new Set(models.recent);
  const available = new Set(models.ids);
  return [...models.recent.filter((item) => available.has(item)), ...models.ids.filter((item) => !recent.has(item))].map((name) => ({ id: name, lower: name.toLowerCase(), recent: recent.has(name) }));
});
const results = computed(() => { const terms = query.value.trim().toLowerCase().split(/\s+/).filter(Boolean); return terms.length ? indexed.value.filter((item) => terms.every((term) => item.lower.includes(term))) : indexed.value; });
const height = computed(() => Math.min(Math.max(104, Math.min(312, viewportHeight.value - 260)), Math.max(ROW, results.value.length * ROW)));
const start = computed(() => Math.max(0, Math.floor(top.value / ROW) - OVERSCAN));
const end = computed(() => Math.min(results.value.length, Math.ceil((top.value + height.value) / ROW) + OVERSCAN));
const visible = computed(() => results.value.slice(start.value, end.value).map((item, index) => ({ ...item, index: start.value + index })));
function reset() { active.value = 0; top.value = 0; if (scroller.value) scroller.value.scrollTop = 0; }
watch(query, reset);
watch(() => models.ids, reset);
async function openList() {
  resize(); open.value = true; query.value = ""; reset(); await nextTick(); search.value?.focus(); root.value?.scrollIntoView?.({ block: "nearest" });
  try { await models.ensure(); } catch { /* The store exposes the request error inside the open panel. */ }
}
function close(restore = false) { open.value = false; if (restore) trigger.value?.focus(); }
function choose(name: string) { value.value = name; emit("commit", name); close(true); void models.remember(name); }
function commit(event: Event) { const name = (event.target as HTMLInputElement).value; emit("commit", name); void models.remember(name); }
async function refresh() { try { await models.ensure(true); } catch { /* Preserve cached choices and show models.error. */ } }
function key(event: KeyboardEvent) {
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(true); return; }
  if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); if (results.value[active.value]) choose(results.value[active.value].id); return; }
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
  event.preventDefault();
  active.value = Math.max(0, Math.min(results.value.length - 1, active.value + (event.key === "ArrowDown" ? 1 : -1)));
  const element = scroller.value; if (!element) return;
  const y = active.value * ROW;
  if (y < element.scrollTop) element.scrollTop = y;
  else if (y + ROW > element.scrollTop + height.value) element.scrollTop = y + ROW - height.value;
  top.value = element.scrollTop;
}
function fieldKey(event: KeyboardEvent) { if (open.value && event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(true); } }
function outside(event: PointerEvent) { if (open.value && event.target instanceof Node && !root.value?.contains(event.target)) close(); }
onMounted(() => { document.addEventListener("pointerdown", outside); window.addEventListener("resize", resize); window.visualViewport?.addEventListener("resize", resize); });
onBeforeUnmount(() => { document.removeEventListener("pointerdown", outside); window.removeEventListener("resize", resize); window.visualViewport?.removeEventListener("resize", resize); });
</script>
<template>
  <div ref="root" class="model-field" @keydown="fieldKey">
    <label class="field" :for="fieldId">{{ label }}</label>
    <div class="model-input-wrap"><input :id="fieldId" v-model="value" type="text" :aria-label="label" :placeholder="placeholder" autocapitalize="none" autocomplete="off" spellcheck="false" @change="commit" /><button ref="trigger" class="icon-button model-trigger" type="button" :aria-label="`选择${label}`" :aria-expanded="open" :aria-controls="listId" @click="open ? close() : openList()"><AppIcon :name="open ? 'close' : 'down'" :size="18" /></button></div>
    <section v-if="open" class="model-menu" :aria-label="`${label}候选列表`">
      <div class="model-search"><AppIcon name="search" :size="18" /><input ref="search" v-model="query" type="search" :aria-label="`搜索${label} ID`" placeholder="搜索模型 ID…" role="combobox" aria-autocomplete="list" aria-expanded="true" :aria-controls="listId" :aria-activedescendant="results[active] && active >= start && active < end ? `${listId}-${active}` : undefined" autocomplete="off" autocapitalize="none" spellcheck="false" @keydown="key" /><button class="icon-button" type="button" :disabled="models.loading" aria-label="刷新模型列表" @click="refresh"><AppIcon name="history" :size="18" /></button></div>
      <div class="model-list-meta" aria-live="polite"><span>{{ models.loading ? '正在读取模型…' : `${models.ids.length} 个模型` }}{{ query.trim() ? ` · 匹配 ${results.length} 个` : '' }}</span><small v-if="models.catalog && !models.loading">已缓存</small></div>
      <p v-if="models.error" class="model-error" role="alert">{{ models.error }}{{ models.ids.length ? '；仍可选择缓存中的模型。' : '' }}</p>
      <button v-if="inherit" type="button" class="model-inherit" @click="choose('')"><AppIcon name="star" :size="17" /><span>使用全局模型<small>{{ inheritedModel || '尚未指定' }}</small></span><AppIcon v-if="!value" name="check" :size="17" /></button>
      <div v-if="results.length" :id="listId" ref="scroller" class="model-list" role="listbox" :aria-label="`${label}列表`" :style="{ height: `${height}px` }" @scroll.passive="top = ($event.target as HTMLElement).scrollTop">
        <div :style="{ height: `${results.length * ROW}px`, position: 'relative' }"><button v-for="item in visible" :id="`${listId}-${item.index}`" :key="item.id" type="button" role="option" :aria-selected="value === item.id" :aria-posinset="item.index + 1" :aria-setsize="results.length" :title="item.id" class="model-option" :class="{ highlighted: active === item.index, 'is-recent': item.recent }" :style="{ top: `${item.index * ROW}px`, height: `${ROW}px` }" @pointerenter="active = item.index" @click="choose(item.id)"><span><strong>{{ item.id }}</strong><small v-if="item.recent">最近选择</small></span><AppIcon v-if="value === item.id" name="check" :size="18" /></button></div>
      </div>
      <p v-else-if="!models.loading" class="model-empty">{{ query.trim() ? '没有匹配的模型。也可以直接在上方输入完整 ID。' : '刷新模型列表，或直接在上方填写模型 ID。' }}</p>
    </section>
  </div>
</template>
<style scoped>
.model-field{min-width:0;display:grid;gap:9px}.model-input-wrap{display:flex;gap:7px;align-items:center}.model-input-wrap>input{flex:1;min-width:0;width:100%}.model-trigger{flex-shrink:0;background:var(--glass-soft);border:1px solid var(--glass-line);border-radius:13px}.model-menu{border:1px solid var(--glass-line);border-radius:16px;overflow:hidden;background:var(--glass-solid);box-shadow:0 8px 28px #0001}.model-search{display:flex;align-items:center;gap:8px;padding:6px 8px 6px 13px;border-bottom:1px solid var(--glass-line);color:var(--muted)}.model-search>input{min-width:0;flex:1;border:0;background:transparent;box-shadow:none;padding:9px 0;font-size:16px;color:var(--ink)}.model-search>.icon-button{width:34px;height:34px;flex-shrink:0}.model-list-meta{display:flex;justify-content:space-between;align-items:center;padding:9px 14px;font-size:12px;color:var(--muted);gap:8px}.model-list-meta>small{font-size:11px;color:var(--accent)}.model-list{overflow:auto;overscroll-behavior:contain;position:relative;scrollbar-width:thin}.model-option{position:absolute;left:0;right:0;width:100%;display:flex;align-items:center;justify-content:space-between;gap:8px;padding:7px 14px;text-align:left;border-top:1px solid var(--glass-line);color:var(--ink)}.model-option>span{min-width:0}.model-option strong{font-size:13px;font-weight:500;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;overflow-wrap:anywhere;line-height:18px}.model-option.is-recent strong{-webkit-line-clamp:1}.model-option small{font-size:10px;color:var(--muted);display:block;line-height:13px}.model-option.highlighted{background:#88d6b014}.model-option[aria-selected=true]{color:var(--accent)}.model-option>svg{flex-shrink:0}.model-error{font-size:12px;color:var(--danger);line-height:1.6;padding:0 14px 10px}.model-empty{font-size:13px;color:var(--muted);padding:14px;line-height:1.65}.model-inherit{display:flex;align-items:center;gap:10px;padding:10px 14px;width:100%;text-align:left;border-bottom:1px solid var(--glass-line);color:var(--accent);font-size:13px}.model-inherit>span{flex:1;min-width:0}.model-inherit small{display:block;font-size:11px;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px}
</style>
