import "fake-indexeddb/auto";
import { reactive } from "vue";
import { beforeEach, describe, expect, test } from "vitest";
import { defaultSettings } from "../domain";
import { createIndexedDbRepository } from "./indexeddb";

describe("indexedDB repository", () => {
  beforeEach(() => {
    indexedDB.deleteDatabase("vcpchat-ios");
  });

  test("persists Vue reactive settings and messages", async () => {
    const repository = createIndexedDbRepository();
    const settings = reactive({ ...defaultSettings(), apiKey: "fixture-key", serverUrl: "http://127.0.0.1:9" });
    await repository.saveSettings(settings);
    expect((await repository.getSettings()).apiKey).toBe("fixture-key");

    const message = reactive({
      id: "m1",
      topicId: "t1",
      role: "user" as const,
      content: "你好",
      reasoning: "",
      attachments: [],
      createdAt: 1,
      status: "complete" as const,
    });
    await repository.saveMessage(message);
    expect((await repository.listMessages("t1"))[0].content).toBe("你好");
  });

  test("fills render switches into settings saved by an older build", async () => {
    const repository = createIndexedDbRepository();
    const legacy: Record<string, unknown> = { ...defaultSettings(), apiKey: "fixture-key" };
    for (const key of Object.keys(legacy)) if (key.startsWith("render") || key === "richRender") delete legacy[key];
    await repository.saveSettings(legacy as never);
    const loaded = await repository.getSettings();
    expect(loaded.apiKey).toBe("fixture-key");
    expect(loaded).toMatchObject({ richRender: true, renderMath: true, renderHtml: true, renderMotion: true });
  });

  test("opening pre-workspace data adds only default main-agent preference", async () => {
    const repository = createIndexedDbRepository();
    const legacy: Record<string, unknown> = { ...defaultSettings(), apiKey: "keep-this-fixture-key" };
    delete legacy.mainAgentId;
    await repository.saveSettings(legacy as never);
    await repository.saveAgent({ id: "original-agent", name: "原来的助手", systemPrompt: "保留提示", model: "old-model", temperature: null, createdAt: 1 });
    await repository.saveTopic({ id: "original-topic", ownerType: "agent", ownerId: "original-agent", title: "以前的会话", turnIndex: 0, createdAt: 1, updatedAt: 2 });
    await repository.saveMessage({ id: "original-message", topicId: "original-topic", role: "assistant", content: "已有内容", reasoning: "", attachments: [], createdAt: 2, status: "complete" });
    const reopened = createIndexedDbRepository();
    expect(await reopened.getSettings()).toMatchObject({ apiKey: "keep-this-fixture-key", mainAgentId: "" });
    expect((await reopened.listAgents())[0]).toMatchObject({ id: "original-agent", systemPrompt: "保留提示" });
    expect((await reopened.listTopics())[0].ownerId).toBe("original-agent");
    expect((await reopened.listMessages("original-topic"))[0].content).toBe("已有内容");
  });
  test("new appearance, voice, regex and image avatars survive reopening; older records keep defaults", async () => {
    const repository = createIndexedDbRepository();
    const legacy: Record<string, unknown> = { ...defaultSettings(), userName: "丝巾" };
    for (const key of Object.keys(legacy)) if (key.startsWith("wallpaper") || key.startsWith("tts") || key === "regexRules") delete legacy[key];
    await repository.saveSettings(legacy as never);
    const old = await repository.getSettings();
    expect(old).toMatchObject({ userName: "丝巾", wallpaper: "forest", ttsUrl: "", ttsKey: "", regexRules: [] });
    await repository.saveSettings({ ...old, wallpaper: "custom", wallpaperCustom: "data:image/webp;base64,fixture", ttsVoice: "Amadeus", ttsSpeed: 0.9 });
    await repository.saveAgent({ id: "photo", name: "Amadeus", systemPrompt: "", model: "", temperature: null, createdAt: 1, avatarUrl: "data:image/webp;base64,avatar", voice: "red", regexRules: [] });
    const reopened = createIndexedDbRepository();
    expect(await reopened.getSettings()).toMatchObject({ wallpaper: "custom", wallpaperCustom: "data:image/webp;base64,fixture", ttsVoice: "Amadeus", ttsSpeed: 0.9 });
    expect((await reopened.listAgents())[0]).toMatchObject({ avatarUrl: "data:image/webp;base64,avatar", voice: "red", regexRules: [] });
  });

});
