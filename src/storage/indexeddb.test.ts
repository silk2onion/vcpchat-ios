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
});