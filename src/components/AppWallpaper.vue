<script setup lang="ts">
import { computed } from "vue";
import { useSettingsStore } from "../stores/settings";
import forest from "../assets/wallpapers/forest-night.jpg";
import leaves from "../assets/wallpapers/leaves.jpg";
const settings = useSettingsStore();
const image = computed(() => settings.settings.wallpaper === "custom" ? settings.settings.wallpaperCustom : settings.settings.wallpaper === "forest" ? forest : settings.settings.wallpaper === "leaves" ? leaves : "");
</script>
<template>
  <div class="app-wallpaper" :class="{ 'has-wallpaper': image }" :style="{ '--wallpaper-image': image ? `url(${JSON.stringify(image)})` : 'none', '--wallpaper-dim': settings.settings.wallpaperDim / 100, '--wallpaper-blur': `${settings.settings.wallpaperBlur}px` }" aria-hidden="true"><div class="wallpaper-image" /><div class="wallpaper-scrim" /></div>
</template>
