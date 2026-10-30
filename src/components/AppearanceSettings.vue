<script setup lang="ts">
import { ref } from "vue";
import { useSettingsStore } from "../stores/settings";
import AppIcon from "./AppIcon.vue";
import { imageData } from "../ui/images";
import forest from "../assets/wallpapers/forest-night.jpg";
import leaves from "../assets/wallpapers/leaves.jpg";
const settings = useSettingsStore();
const error = ref("");
const uploading = ref(false);
const options = [{ id: "forest", name: "林间夜游", image: forest }, { id: "leaves", name: "雨后绿叶", image: leaves }, { id: "none", name: "纯色", image: "" }] as const;
async function upload(event: Event) {
  const input = event.target as HTMLInputElement; const file = input.files?.[0]; input.value = "";
  if (!file) return;
  error.value = ""; uploading.value = true;
  try { const data = await imageData(file, 2560); await settings.patch({ wallpaper: "custom", wallpaperCustom: data }); }
  catch (caught) { error.value = caught instanceof Error ? caught.message : "图片没有读出来"; }
  finally { uploading.value = false; }
}
</script>
<template>
  <div class="stack appearance-editor">
    <div class="section-heading"><AppIcon name="palette" /><div><h2>主题</h2><p>让文字、面板和壁纸彼此衬托。</p></div></div>
    <div class="theme-choices">
      <button v-for="theme in [{ id: 'ink', name: '墨色' }, { id: 'paper', name: '纸色' }, { id: 'aurora', name: '极光' }] as const" :key="theme.id" type="button" class="theme-choice" :class="{ chosen: settings.settings.theme === theme.id }" :aria-pressed="settings.settings.theme === theme.id" @click="settings.patch({ theme: theme.id })"><span class="theme-preview" :class="theme.id"><i /><i /><i /></span><strong>{{ theme.name }}</strong><AppIcon v-if="settings.settings.theme === theme.id" name="check" :size="18" /></button>
    </div>
    <div class="section-heading"><AppIcon name="image" /><div><h2>壁纸</h2><p>也可以使用自己的照片。</p></div></div>
    <div class="wallpaper-choices">
      <button v-for="option in options" :key="option.id" class="wallpaper-choice" :class="{ chosen: settings.settings.wallpaper === option.id }" type="button" :aria-pressed="settings.settings.wallpaper === option.id" @click="settings.patch({ wallpaper: option.id })"><img v-if="option.image" :src="option.image" alt="" /><span v-else class="solid-wallpaper" /><span>{{ option.name }}<AppIcon v-if="settings.settings.wallpaper === option.id" name="check" :size="16" /></span></button>
      <button v-if="settings.settings.wallpaperCustom" class="wallpaper-choice" :class="{ chosen: settings.settings.wallpaper === 'custom' }" type="button" :aria-pressed="settings.settings.wallpaper === 'custom'" @click="settings.patch({ wallpaper: 'custom' })"><img :src="settings.settings.wallpaperCustom" alt="自定义壁纸预览" /><span>自定义<AppIcon v-if="settings.settings.wallpaper === 'custom'" name="check" :size="16" /></span></button>
      <label v-else class="wallpaper-choice wallpaper-upload"><AppIcon name="upload" :size="28" /><span>{{ uploading ? '正在导入…' : '选取照片' }}</span><input class="sr-only" type="file" accept="image/jpeg,image/png,image/webp,image/gif" aria-label="上传自定义壁纸" :disabled="uploading" @change="upload" /></label>
    </div>
    <label v-if="settings.settings.wallpaperCustom" class="text-button file-action"><AppIcon name="image" :size="17" />更换自定义壁纸<input class="sr-only" type="file" accept="image/jpeg,image/png,image/webp,image/gif" aria-label="更换自定义壁纸" :disabled="uploading" @change="upload" /></label>
    <div v-if="settings.settings.wallpaper !== 'none'" class="settings-group wallpaper-tuning">
      <label class="range-field"><span>背景遮罩<strong>{{ settings.settings.wallpaperDim }}%</strong></span><input v-model.number="settings.settings.wallpaperDim" type="range" min="15" max="90" aria-label="壁纸遮罩" @change="settings.patch({ wallpaperDim: settings.settings.wallpaperDim })" /></label>
      <label class="range-field"><span>背景模糊<strong>{{ settings.settings.wallpaperBlur }} px</strong></span><input v-model.number="settings.settings.wallpaperBlur" type="range" min="0" max="16" aria-label="壁纸模糊" @change="settings.patch({ wallpaperBlur: settings.settings.wallpaperBlur })" /></label>
    </div>
    <p v-if="error" class="error-line" role="alert">{{ error }}</p>
  </div>
</template>
