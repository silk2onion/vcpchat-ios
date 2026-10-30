import { defineStore } from "pinia";
import { ref } from "vue";
import { defaultSettings, type Settings, type ThemeId } from "../domain";
import { getRepository } from "../storage";

export const useSettingsStore = defineStore("settings", () => {
  const settings = ref<Settings>(defaultSettings());
  const ready = ref(false);
  const status = ref("");

  async function load() {
    settings.value = await getRepository().getSettings();
    applyTheme(settings.value.theme);
    ready.value = true;
  }

  async function patch(partial: Partial<Settings>) {
    settings.value = { ...settings.value, ...partial };
    applyTheme(settings.value.theme);
    await getRepository().saveSettings(settings.value);
    status.value = "已保存在这台设备上";
  }

  async function clearSecrets() {
    await patch({ apiKey: "", logKey: "", adminPassword: "" });
    status.value = "密钥已从本机设置里清除";
  }

  return { settings, ready, status, load, patch, clearSecrets };
});

export function applyTheme(theme: ThemeId) {
  if (typeof document === "undefined") return;
  document.documentElement.dataset.theme = theme;
  const colors: Record<ThemeId, string> = {
    ink: "#101214",
    paper: "#f6f7f8",
    aurora: "#101b21",
  };
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", colors[theme]);
}
