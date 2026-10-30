import type { Agent, Settings } from "../domain";
import { createAppHttp, formatHttpError, isTauri } from "./http";
import { parseSegments } from "./tools";

export interface Voice { voice: string; name: string }
export const mimoVoices: Voice[] = ["mimo_default", "冰糖", "茉莉", "苏打", "白桦", "Mia", "Chloe", "Milo", "Dean", "mimo:natural-control"].map((voice) => ({ voice, name: voice === "mimo:natural-control" ? "自然语言导演" : voice === "mimo_default" ? "默认音色" : voice }));

function base(url: string): string {
  const parsed = new URL(url.trim());
  if (!["http:", "https:"].includes(parsed.protocol) || parsed.username || parsed.password) throw new Error("请填写 HTTP 或 HTTPS 语音服务地址");
  return parsed.toString().replace(/\/+$/, "");
}
export function speechHeaders(key: string): Record<string, string> {
  return { "Content-Type": "application/json", ...(key.trim() ? { Authorization: `Bearer ${key.trim()}` } : {}) };
}

export async function listVoices(settings: Settings): Promise<Voice[]> {
  if (settings.ttsMode === "mimo") return mimoVoices;
  const http = await createAppHttp();
  const response = await http.request({ method: "POST", url: `${base(settings.ttsUrl)}/models`, headers: speechHeaders(settings.ttsKey), body: JSON.stringify({ version: "v2ProPlus" }) });
  if (response.status < 200 || response.status >= 300) throw new Error(formatHttpError(response.status, response.body, [settings.ttsKey]));
  const data = JSON.parse(response.body);
  if (data.msg !== "获取成功" || !data.models) throw new Error("语音服务未返回 VChat 兼容的音色列表");
  const voices = Array.isArray(data.models)
    ? data.models.map((m: Record<string, unknown>) => ({ voice: String(m.voice || m.uri || m.id || ""), name: String(m.displayName || m.customName || m.name || m.voice || m.uri || m.id || "") }))
    : Object.keys(data.models).map((voice) => ({ voice, name: voice }));
  return voices.filter((v: Voice, i: number) => v.voice && voices.findIndex((other: Voice) => other.voice === v.voice) === i);
}

export function speechRequest(settings: Settings, input: string, agent?: Agent) {
  const voice = agent?.voice || settings.ttsVoice;
  const speed = agent?.speechSpeed ?? settings.ttsSpeed;
  const director = agent?.speechDirector || settings.ttsDirector;
  const url = base(settings.ttsUrl);
  if (settings.ttsMode === "mimo") {
    if (!settings.ttsKey.trim()) throw new Error("请填写 MiMo 语音 API Key");
    if (voice === "mimo:natural-control" && !director.trim()) throw new Error("自然语言导演音色需要填写导演提示词");
    return { url: /\/chat\/completions$/i.test(url) ? url : `${url}/chat/completions`, body: {
      model: voice === "mimo:natural-control" ? `${settings.ttsModel || "mimo-v2.5-tts"}-voicedesign` : settings.ttsModel || "mimo-v2.5-tts",
      messages: [...(director.trim() ? [{ role: "user", content: director.trim() }] : []), { role: "assistant", content: input }],
      audio: { format: "pcm16", ...(voice && voice !== "mimo:natural-control" ? { voice } : voice ? {} : { voice: "mimo_default" }) }, stream: true,
    } };
  }
  if (!voice) throw new Error("先选择一个 SoVITS 音色");
  const japanese = voice.includes("日语");
  return { url: `${url}/v1/audio/speech`, body: { model: "tts-v2ProPlus", input, voice, response_format: "mp3", speed, other_params: { text_lang: japanese ? "日语" : "中英混合", prompt_lang: japanese ? "日语" : "中文", emotion: "默认", text_split_method: "按标点符号切" } } };
}

export function pcmToWav(pcm: Uint8Array): Uint8Array {
  const wav = new Uint8Array(44 + pcm.length);
  const view = new DataView(wav.buffer);
  for (const [offset, value] of [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [36, "data"]] as const) wav.set(new TextEncoder().encode(value), offset);
  view.setUint32(4, 36 + pcm.length, true); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 24000, true); view.setUint32(28, 48000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); view.setUint32(40, pcm.length, true);
  wav.set(pcm, 44);
  return wav;
}

export function mimoAudio(source: string): Uint8Array {
  const chunks: Uint8Array[] = [];
  for (const line of source.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const raw = line.slice(5).trim();
    if (!raw || raw === "[DONE]") continue;
    let data;
    try { data = JSON.parse(raw); } catch { continue; }
    if (data.error) throw new Error(data.error.message || String(data.error));
    const encoded = data.choices?.[0]?.delta?.audio?.data;
    if (encoded) chunks.push(Uint8Array.from(atob(encoded), (char) => char.charCodeAt(0)));
  }
  if (!chunks.length) throw new Error("MiMo 返回的流里没有音频");
  const pcm = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0; for (const chunk of chunks) { pcm.set(chunk, offset); offset += chunk.length; }
  return pcmToWav(pcm);
}

export function spokenText(content: string): string {
  return parseSegments(content).filter((s) => s.type === "text").map((s) => s.type === "text" ? s.text : "").join("\n")
    .replace(/```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)/g, "")
    .replace(/<style\b[\s\S]*?<\/style>|<script\b[\s\S]*?<\/script>/gi, "")
    .replace(/<\/?[a-z][^>]*>/gi, "").replace(/!\[[^\]]*\]\([^)]*\)/g, "").replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*#_`~]/g, "").trim();
}

export async function synthesize(settings: Settings, input: string, agent?: Agent): Promise<Blob> {
  const request = speechRequest(settings, input, agent);
  const headers = speechHeaders(settings.ttsKey);
  let bytes: Uint8Array;
  if (isTauri()) {
    const { invoke } = await import("@tauri-apps/api/core");
    bytes = new Uint8Array(await invoke<ArrayBuffer>("audio_request", { url: request.url, headers, body: JSON.stringify(request.body) }));
  } else {
    const response = await fetch(request.url, { method: "POST", headers, body: JSON.stringify(request.body) });
    if (!response.ok) throw new Error(formatHttpError(response.status, await response.text(), [settings.ttsKey]));
    const type = response.headers.get("content-type") || "";
    if (!type.startsWith("audio/") && !type.includes("text/event-stream")) throw new Error("语音服务没有返回音频");
    const buffer = await response.arrayBuffer();
    if (buffer.byteLength > 16_000_000) throw new Error("语音超过 16MB，请分段朗读");
    bytes = new Uint8Array(buffer);
  }
  if (settings.ttsMode === "mimo") bytes = mimoAudio(new TextDecoder().decode(bytes));
  const wav = new TextDecoder().decode(bytes.slice(0, 4)) === "RIFF";
  return new Blob([bytes.slice().buffer], { type: wav ? "audio/wav" : "audio/mpeg" });
}
