import { afterEach, describe, expect, test, vi } from "vitest";
import { defaultSettings, type Agent } from "../domain";
import { listVoices, mimoAudio, pcmToWav, speechRequest, spokenText, synthesize } from "./speech";
const settings = () => ({ ...defaultSettings(), ttsUrl: "http://127.0.0.1:8000/", ttsVoice: "Amadeus", ttsKey: "fixture" });
afterEach(() => vi.unstubAllGlobals());
describe("desktop-compatible voice requests", () => {
  test("uses the VChat SoVITS path, body and language defaults", () => {
    expect(speechRequest(settings(), "你好")).toEqual({ url: "http://127.0.0.1:8000/v1/audio/speech", body: { model: "tts-v2ProPlus", input: "你好", voice: "Amadeus", response_format: "mp3", speed: 1, other_params: { text_lang: "中英混合", prompt_lang: "中文", emotion: "默认", text_split_method: "按标点符号切" } } });
    const agent: Agent = { id: "a", name: "红莉栖", systemPrompt: "", model: "", temperature: null, createdAt: 1, voice: "红莉栖日语", speechSpeed: 0.8 };
    expect(speechRequest(settings(), "こんにちは", agent).body).toMatchObject({ voice: "红莉栖日语", speed: 0.8, other_params: { text_lang: "日语", prompt_lang: "日语" } });
  });
  test("uses MiMo streaming PCM and voice design without a duplicate URL suffix", () => {
    const s = { ...settings(), ttsMode: "mimo" as const, ttsUrl: "https://example.test/v1/chat/completions", ttsVoice: "mimo:natural-control", ttsDirector: "轻声" };
    expect(speechRequest(s, "你好")).toEqual({ url: s.ttsUrl, body: { model: "mimo-v2.5-tts-voicedesign", messages: [{ role: "user", content: "轻声" }, { role: "assistant", content: "你好" }], audio: { format: "pcm16" }, stream: true } });
    expect(() => speechRequest({ ...s, ttsDirector: "" }, "你好")).toThrow("导演");
    expect(() => speechRequest({ ...s, ttsKey: "" }, "你好")).toThrow("API Key");
    expect(() => speechRequest({ ...s, ttsUrl: "file:///a" }, "你好")).toThrow("HTTP");
  });
  test("loads desktop model arrays and reports service errors", async () => {
    const fetcher = vi.fn().mockResolvedValue(new Response(JSON.stringify({ msg: "获取成功", models: [{ voice: "a", displayName: "小红" }, { uri: "b", name: "助手" }, { voice: "a" }] })));
    vi.stubGlobal("fetch", fetcher);
    expect(await listVoices(settings())).toEqual([{ voice: "a", name: "小红" }, { voice: "b", name: "助手" }]);
    expect(JSON.parse(fetcher.mock.calls[0][1].body)).toEqual({ version: "v2ProPlus" });
    fetcher.mockResolvedValue(new Response('{"error":{"message":"fixture denied"}}', { status: 403 }));
    await expect(listVoices(settings())).rejects.toThrow("•••• denied");
  });
  test("wraps all MiMo audio chunks in a real 24 kHz mono WAV", () => {
    const wav = mimoAudio('data: heartbeat\r\ndata: {"choices":[{"delta":{"audio":{"data":"AQI="}}}]}\r\ndata: {"choices":[{"delta":{"audio":{"data":"AwQ="}}}]}\r\ndata: [DONE]\r\n');
    expect(new TextDecoder().decode(wav.slice(0, 4))).toBe("RIFF");
    expect([...wav.slice(44)]).toEqual([1, 2, 3, 4]);
    expect(new DataView(wav.buffer).getUint32(24, true)).toBe(24000);
    expect(pcmToWav(new Uint8Array(4))).toHaveLength(48);
    expect(() => mimoAudio('data: {"error":{"message":"bad voice"}}')).toThrow("bad voice");
    expect(() => mimoAudio('data: [DONE]')).toThrow("没有音频");
  });
  test("reads prose, not tools, code, style or hidden thought", () => {
    expect(spokenText('你好 **丝巾** [链接](https://example.test)\n```js\nsecret()\n```\n<style>x{}</style>\n<details><summary>显示</summary>正文</details>\n3 < 5 > 2')).toContain("你好 丝巾 链接");
    expect(spokenText('正文\n<<<[TOOL_REQUEST]>>>\ntool_name:「始」FileOperator「末」\n<<<[END_TOOL_REQUEST]>>>')).toBe("正文");
    expect(spokenText('3 < 5 > 2')).toBe('3 < 5 > 2');
  });
  test("accepts real audio and rejects JSON masquerading as speech", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(pcmToWav(new Uint8Array(4)).slice().buffer, { headers: { "Content-Type": "audio/wav" } })));
    expect((await synthesize(settings(), "你好")).type).toBe("audio/wav");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response('{}', { headers: { "Content-Type": "application/json" } })));
    await expect(synthesize(settings(), "你好")).rejects.toThrow("没有返回音频");
  });
});
