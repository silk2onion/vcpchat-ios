import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, test } from "vitest";
import type { ChatMessage } from "../domain";
import { setChatTransport, StreamLostError, type ChatStreamHandlers } from "../protocol/transport";
import { getRepository, installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { CONTINUE_PROMPT, useLibraryStore } from "./library";
import { useSettingsStore } from "./settings";

async function configured() {
  const settings = useSettingsStore();
  await settings.load();
  await settings.patch({ serverUrl: "http://127.0.0.1:6005", apiKey: "fixture-key", defaultModel: "demo-model" });
  const library = useLibraryStore();
  await library.load();
  return library;
}

/** A transport whose single stream is driven by the test. */
function manualTransport() {
  let handlers: ChatStreamHandlers | null = null;
  let settle: (error?: Error) => void = () => {};
  const bodies: string[] = [];
  setChatTransport({
    stream(options) {
      handlers = options.handlers;
      bodies.push(options.body);
      return new Promise<void>((resolve, reject) => {
        settle = (error) => (error ? reject(error) : resolve());
      });
    },
  });
  return {
    bodies,
    write: (text: string) => handlers?.onContent(text),
    end: (error?: Error) => settle(error),
  };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

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

  test("a reply keeps streaming into its own topic while another topic is open", async () => {
    const stream = manualTransport();
    const library = await configured();
    const first = library.topicId;
    const sending = library.send("写首诗", []);
    await tick();
    stream.write("床前");
    await library.createTopic();
    const second = library.topicId;
    expect(library.streaming).toBe(false);
    expect(library.messages).toHaveLength(0);
    stream.write("明月光");
    stream.end();
    await sending;
    const saved = await getRepository().listMessages(first);
    expect(saved.map((message) => [message.content, message.status])).toEqual([
      ["写首诗", "complete"],
      ["床前明月光", "complete"],
    ]);
    expect(await getRepository().listMessages(second)).toEqual([]);
    await library.selectTopic(first);
    expect(library.messages.at(-1)?.content).toBe("床前明月光");
  });

  test("switching back mid-stream shows the live reply", async () => {
    const stream = manualTransport();
    const library = await configured();
    const first = library.topicId;
    const sending = library.send("说", []);
    await tick();
    await library.createTopic();
    stream.write("一半");
    await library.selectTopic(first);
    expect(library.streaming).toBe(true);
    expect(library.messages.at(-1)).toMatchObject({ content: "一半", status: "streaming" });
    stream.end();
    await sending;
  });

  test("a dropped connection keeps the partial reply and can be continued", async () => {
    const stream = manualTransport();
    const library = await configured();
    const sending = library.send("讲个故事", []);
    await tick();
    stream.write("从前有座山，");
    stream.end(new Error("流中断: connection reset"));
    await sending;
    const cut = library.messages.at(-1) as ChatMessage;
    expect(cut).toMatchObject({ status: "interrupted", content: "从前有座山，" });
    expect((await getRepository().listMessages(library.topicId)).at(-1)?.status).toBe("interrupted");

    const resuming = library.continueMessage(cut.id);
    await tick();
    const request = JSON.parse(stream.bodies.at(-1) ?? "{}");
    expect(request.messages.at(-2)).toEqual({ role: "assistant", content: "从前有座山，" });
    expect(request.messages.at(-1)).toEqual({ role: "user", content: CONTINUE_PROMPT });
    stream.write("山里有座庙。");
    stream.end();
    await resuming;
    expect(library.messages).toHaveLength(2);
    expect(library.messages.at(-1)).toMatchObject({ status: "complete", content: "从前有座山，山里有座庙。" });
  });

  test("an error before any text is a failure, not an interruption", async () => {
    const stream = manualTransport();
    const library = await configured();
    const sending = library.send("你好", []);
    await tick();
    stream.end(new Error("HTTP 500"));
    await sending;
    expect(library.messages.at(-1)).toMatchObject({ status: "error", error: "HTTP 500" });
  });

  test("going to the background writes the partial reply to storage at once", async () => {
    const stream = manualTransport();
    const library = await configured();
    const sending = library.send("长文", []);
    await tick();
    stream.write("第一段");
    await library.flushStreams();
    expect((await getRepository().listMessages(library.topicId)).at(-1)).toMatchObject({ content: "第一段", status: "streaming" });
    stream.end();
    await sending;
  });

  test("after a restart an unfinished reply without a live stream is marked interrupted", async () => {
    const library = await configured();
    await getRepository().saveMessage({
      id: "m-cut",
      topicId: library.topicId,
      role: "assistant",
      content: "写到一半",
      reasoning: "",
      attachments: [],
      createdAt: 5,
      status: "streaming",
    });
    await library.recoverStreams();
    expect((await getRepository().listMessages(library.topicId))[0]).toMatchObject({ status: "interrupted", content: "写到一半" });
  });

  test("after a reload a reply still streaming in the native layer is re-attached", async () => {
    const library = await configured();
    const replays: string[] = [];
    setChatTransport({
      async stream() {},
      async resume({ streamId, handlers }) {
        replays.push(streamId);
        handlers.onContent("前半");
        handlers.onContent("后半");
      },
      async release() {},
    });
    await getRepository().saveMessage({
      id: "m-live",
      topicId: library.topicId,
      role: "assistant",
      content: "旧的前",
      reasoning: "",
      attachments: [],
      createdAt: 5,
      status: "streaming",
      streamId: "s-1",
      streamOffset: { content: 2, reasoning: 0 },
    });
    await library.recoverStreams();
    expect(replays).toEqual(["s-1"]);
    const saved = (await getRepository().listMessages(library.topicId))[0];
    expect(saved).toMatchObject({ status: "complete", content: "旧的前半后半" });
    expect(saved.streamId).toBeUndefined();
  });

  test("a re-attach that finds the stream gone keeps what was saved", async () => {
    const library = await configured();
    setChatTransport({
      async stream() {},
      async resume() {
        throw new StreamLostError();
      },
    });
    await getRepository().saveMessage({
      id: "m-gone",
      topicId: library.topicId,
      role: "assistant",
      content: "已保存的部分",
      reasoning: "",
      attachments: [],
      createdAt: 5,
      status: "streaming",
      streamId: "s-2",
    });
    await library.recoverStreams();
    expect((await getRepository().listMessages(library.topicId))[0]).toMatchObject({ status: "interrupted", content: "已保存的部分" });
  });

  test("deleting a topic mid-stream does not write the reply back", async () => {
    const stream = manualTransport();
    const library = await configured();
    const doomed = library.topicId;
    const sending = library.send("删掉我", []);
    await tick();
    stream.write("残留");
    await library.removeTopic(doomed);
    stream.end();
    await sending;
    await library.flushStreams();
    expect(await getRepository().listMessages(doomed)).toEqual([]);
  });
});
