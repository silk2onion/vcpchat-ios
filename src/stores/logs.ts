import { defineStore } from "pinia";
import { ref } from "vue";
import type { LogEntry } from "../domain";
import { LIMITS } from "../domain";
import { buildInfoSocketUrl, buildLogSocketUrl } from "../protocol/endpoint";
import { createId } from "../protocol/ids";
import { summarizePayload } from "../protocol/logs";
import { nextDelay } from "../protocol/groups";
import { redactSecrets } from "../protocol/redact";
import { isTauri } from "../protocol/http";
import { getRepository } from "../storage";
import { useSettingsStore } from "./settings";

type Channel = "log" | "info";

const CHANNELS: Channel[] = ["log", "info"];
/** After this long in the background a socket that still looks open is assumed dead. */
const STALE_AFTER_MS = 20_000;

export const useLogStore = defineStore("logs", () => {
  const entries = ref<LogEntry[]>([]);
  const status = ref<Record<Channel, string>>({ log: "未连接", info: "未连接" });
  let sockets: Partial<Record<Channel, WebSocket>> = {};
  const delays: Record<Channel, number> = { log: 1000, info: 1000 };
  let timers: Partial<Record<Channel, number>> = {};
  let urls: Partial<Record<Channel, string>> = {};
  let native = false;
  let unlisten: (() => void) | null = null;

  async function load() {
    entries.value = await getRepository().listLogs();
  }

  async function reconnect() {
    await disconnect();
    await sync();
  }

  async function sync() {
    const settings = useSettingsStore().settings;
    if (!settings.logUrl.trim() || !settings.logKey.trim()) {
      await disconnect();
      status.value = { log: "未配置", info: "未配置" };
      return;
    }
    let next: Record<Channel, string>;
    try {
      next = {
        log: buildLogSocketUrl(settings.logUrl, settings.logKey),
        info: buildInfoSocketUrl(settings.logUrl, settings.logKey),
      };
    } catch (error) {
      status.value = { log: error instanceof Error ? error.message : "地址无效", info: "地址无效" };
      return;
    }
    if (next.log === urls.log && next.info === urls.info) return;
    await disconnect();
    urls = next;
    if (isTauri()) await connectNative(next);
    else {
      connectBrowser("log", next.log);
      connectBrowser("info", next.info);
    }
  }

  function connectBrowser(channel: Channel, url: string) {
    status.value = { ...status.value, [channel]: "连接中" };
    const socket = new WebSocket(url);
    sockets[channel] = socket;
    socket.onopen = () => {
      delays[channel] = 1000;
      status.value = { ...status.value, [channel]: "已连接" };
    };
    socket.onmessage = (event) => {
      void push(channel, event.data);
    };
    socket.onerror = () => {
      status.value = { ...status.value, [channel]: "连接失败" };
    };
    socket.onclose = () => {
      if (sockets[channel] !== socket) return;
      status.value = { ...status.value, [channel]: "已断开" };
      const wait = delays[channel];
      delays[channel] = nextDelay(wait);
      timers[channel] = window.setTimeout(() => {
        if (urls[channel] === url) connectBrowser(channel, url);
      }, wait);
    };
  }

  async function connectNative(next: Record<Channel, string>) {
    native = true;
    const [{ invoke }, { listen }] = await Promise.all([import("@tauri-apps/api/core"), import("@tauri-apps/api/event")]);
    unlisten = await listen<{ channel: Channel; kind: string; text: string }>("vcp-socket", (event) => {
      const channel = event.payload.channel;
      if (event.payload.kind === "status") status.value = { ...status.value, [channel]: event.payload.text };
      if (event.payload.kind === "message") void push(channel, event.payload.text);
      if (event.payload.kind === "error") status.value = { ...status.value, [channel]: redact(event.payload.text) };
    });
    await invoke("socket_connect", { channel: "log", url: next.log });
    await invoke("socket_connect", { channel: "info", url: next.info });
  }

  /** Called when the app comes back to the foreground: reconnect now instead of waiting out the backoff. */
  async function resume(hiddenForMs: number) {
    if (!urls.log || !urls.info) return;
    const stale = hiddenForMs >= STALE_AFTER_MS;
    if (native) {
      const { invoke } = await import("@tauri-apps/api/core");
      for (const channel of CHANNELS) {
        if (!stale && status.value[channel] === "已连接") continue;
        await invoke("socket_connect", { channel, url: urls[channel] });
      }
      return;
    }
    for (const channel of CHANNELS) {
      const socket = sockets[channel];
      if (!stale && socket?.readyState === WebSocket.OPEN) continue;
      window.clearTimeout(timers[channel]);
      delete timers[channel];
      delete sockets[channel];
      socket?.close();
      delays[channel] = 1000;
      const url = urls[channel];
      if (url) connectBrowser(channel, url);
    }
  }

  async function push(channel: Channel, raw: unknown) {
    let payload: unknown = raw;
    if (typeof raw === "string") {
      try {
        payload = JSON.parse(raw);
      } catch {
        payload = raw;
      }
    }
    const summary = summarizePayload(payload);
    const entry: LogEntry = {
      id: createId("log"),
      channel,
      title: redact(summary.title),
      detail: redact(summary.detail),
      createdAt: Date.now(),
    };
    entries.value = [...entries.value, entry].slice(-LIMITS.maxLogEntries);
    await getRepository().saveLogs(entries.value);
  }

  function redact(text: string): string {
    const settings = useSettingsStore().settings;
    return redactSecrets(text, [settings.apiKey, settings.logKey, settings.adminPassword]);
  }

  async function disconnect() {
    for (const timer of Object.values(timers)) window.clearTimeout(timer);
    timers = {};
    for (const socket of Object.values(sockets)) socket?.close();
    sockets = {};
    urls = {};
    if (native) {
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("socket_disconnect", { channel: "log" });
      await invoke("socket_disconnect", { channel: "info" });
      unlisten?.();
      unlisten = null;
      native = false;
    }
  }

  async function clear() {
    entries.value = [];
    await getRepository().saveLogs([]);
  }

  return { entries, status, load, sync, reconnect, resume, disconnect, clear };
});
