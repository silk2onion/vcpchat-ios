import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, test } from "vitest";
import { setChatTransport } from "../protocol/transport";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useLibraryStore } from "./library";
import { useSettingsStore } from "./settings";

describe("conversation store", () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    installRepository(createMemoryRepository());
    setChatTransport({
      async stream({ handlers }) {
        handlers.onReasoning("想一下");
        handlers.onContent("这是流式回复");
      },
    });
  });

  test("stores a streamed reply on the device", async () => {
    const settings = useSettingsStore();
    await settings.load();
    await settings.patch({
      serverUrl: "http://127.0.0.1:6005",
      apiKey: "fixture-key",
      defaultModel: "demo-model",
      endpointMode: "standard",
    });
    const library = useLibraryStore();
    await library.load();
    await library.send("今天天气", []);
    expect(library.messages.map((message) => message.content)).toEqual(["今天天气", "这是流式回复"]);
    expect(library.messages[1].reasoning).toBe("想一下");
    expect(library.messages[1].status).toBe("complete");
    const saved = await (await import("../storage")).getRepository().listMessages(library.topicId);
    expect(saved).toHaveLength(2);
    expect(library.currentTopic?.title).toBe("今天天气");
  });

  test("asks every group member in order", async () => {
    const seen: string[] = [];
    setChatTransport({
      async stream({ body, handlers }) {
        seen.push(JSON.parse(body).messages.at(-1).content);
        handlers.onContent("好");
      },
    });
    const settings = useSettingsStore();
    await settings.load();
    await settings.patch({ serverUrl: "http://127.0.0.1:6005", apiKey: "fixture-key", defaultModel: "demo-model" });
    const library = useLibraryStore();
    await library.load();
    await library.createAgent("舟");
    const first = library.agents[0];
    const second = library.agents[1];
    await library.createGroup("圆桌", [first.id, second.id], "all");
    await library.send("都说说", []);
    expect(library.messages.filter((message) => message.role === "assistant").map((message) => message.authorName)).toEqual(["助手", "舟"]);
    expect(seen).toHaveLength(2);
  });
});
