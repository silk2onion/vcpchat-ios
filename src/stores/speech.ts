import { computed, ref } from "vue";
import { defineStore } from "pinia";
import type { Agent } from "../domain";
import { secretsOf } from "../domain";
import { redactSecrets } from "../protocol/redact";
import { listVoices, spokenText, synthesize, type Voice } from "../protocol/speech";
import { useSettingsStore } from "./settings";

export const useSpeechStore = defineStore("speech", () => {
  const voices = ref<Voice[]>([]);
  const phase = ref<"idle" | "loading" | "playing" | "paused" | "ready" | "error">("idle");
  const messageId = ref("");
  const speaker = ref("");
  const error = ref("");
  const elapsed = ref(0);
  const duration = ref(0);
  const active = computed(() => phase.value !== "idle");
  let audio: HTMLAudioElement | null = null;
  let url = "";
  let session = 0;
  let finishPlayback: (() => void) | null = null;

  async function refreshVoices() { voices.value = await listVoices(useSettingsStore().settings); return voices.value; }
  function stop() {
    session++;
    if (audio) { audio.onended = null; audio.onerror = null; audio.ontimeupdate = null; audio.pause(); audio = null; }
    if (url) URL.revokeObjectURL(url); url = "";
    finishPlayback?.(); finishPlayback = null;
    phase.value = "idle"; messageId.value = ""; elapsed.value = 0; duration.value = 0;
  }
  async function toggle() {
    if (!audio) return;
    if (phase.value === "playing") { audio.pause(); phase.value = "paused"; }
    else {
      try { await audio.play(); phase.value = "playing"; error.value = ""; }
      catch { phase.value = "ready"; error.value = "点播放开始朗读"; }
    }
  }
  async function read(id: string, content: string, agent?: Agent) {
    stop();
    const own = session;
    const settings = { ...useSettingsStore().settings };
    messageId.value = id; speaker.value = agent?.name || "语音试听"; phase.value = "loading"; error.value = "";
    const text = spokenText(content);
    if (!text) { phase.value = "error"; error.value = "这条消息没有可朗读的正文"; return; }
    // Short segments keep mobile requests and audio buffers bounded.
    const segments = text.match(/[\s\S]{1,800}(?:[。！？.!?\n]|$)|[\s\S]{1,800}/g) || [text];
    try {
      for (const segment of segments) {
        if (own !== session) return;
        phase.value = "loading";
        const blob = await synthesize(settings, segment, agent);
        if (own !== session) return;
        url = URL.createObjectURL(blob);
        const player = new Audio(url); audio = player;
        const done = new Promise<void>((resolve, reject) => {
          finishPlayback = resolve;
          player.onended = () => resolve();
          player.onerror = () => reject(new Error("音频无法解码，请检查语音服务返回的格式"));
          player.ontimeupdate = () => { elapsed.value = player.currentTime; duration.value = Number.isFinite(player.duration) ? player.duration : 0; };
        });
        try { await player.play(); phase.value = "playing"; }
        catch { phase.value = "ready"; error.value = "点播放开始朗读"; }
        await done;
        if (own !== session) return;
        URL.revokeObjectURL(url); url = ""; audio = null;
      }
      if (own === session) stop();
    } catch (caught) {
      if (own !== session) return;
      audio?.pause(); audio = null;
      if (url) URL.revokeObjectURL(url); url = "";
      finishPlayback = null;
      phase.value = "error";
      error.value = redactSecrets(caught instanceof Error ? caught.message : String(caught), secretsOf(settings));
    }
  }
  return { voices, phase, messageId, speaker, error, elapsed, duration, active, stop, toggle, read, refreshVoices };
});
