// @vitest-environment jsdom
import { describe, expect, test } from "vitest";
import { createBrowserTransport, createNativeTransport, StreamLostError, type NativeBridge } from "./transport";

const frame = (text: string) => `data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\n`;

/** Stands in for the Rust side: a chunk log plus an event channel the test can drop events from. */
function fakeNative() {
  const log: string[] = [];
  let state: "running" | "done" | "error" | "cancelled" | "missing" = "running";
  let error = "";
  let handler: Parameters<NativeBridge["listen"]>[0] = () => {};
  const calls: string[] = [];
  const bridge: NativeBridge = {
    async invoke<T>(command: string, args: Record<string, unknown>) {
      calls.push(command);
      if (command === "chat_stream_snapshot") {
        const fromSeq = args.fromSeq as number;
        return { fromSeq, chunks: log.slice(fromSeq), state, error } as T;
      }
      if (command === "cancel_chat_stream") state = "cancelled";
      return undefined as T;
    },
    async listen(next) {
      handler = next;
      return () => {
        handler = () => {};
      };
    },
  };
  return {
    bridge,
    calls,
    chunk(text: string, deliver = true) {
      log.push(text);
      if (deliver) handler({ requestId: "r", kind: "chunk", text, seq: log.length - 1 });
    },
    end(kind: "done" | "error", message = "", deliver = true) {
      state = kind;
      error = message;
      if (deliver) handler({ requestId: "r", kind, text: message, seq: log.length });
    },
    setState(next: typeof state) {
      state = next;
    },
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("browser streaming", () => {
  test("follows SSE frames from fetch", async () => {
    const encoder = new TextEncoder();
    const chunks = ['data: {"choices":[{"delta":{"content":"甲"}}]}\n\n', 'data: {"choices":[{"delta":{"reasoning_content":"乙"}}]}\n\n', "data: [DONE]\n\n"];
    const fetchImpl: typeof fetch = async () =>
      new Response(
        new ReadableStream({
          start(controller) {
            for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
            controller.close();
          },
        }),
        { status: 200, headers: { "content-type": "text/event-stream" } },
      );
    const content: string[] = [];
    const reasoning: string[] = [];
    await createBrowserTransport(fetchImpl).stream({
      url: "http://127.0.0.1:9/v1/chat/completions",
      apiKey: "fixture-key",
      body: "{}",
      signal: new AbortController().signal,
      handlers: {
        onContent: (text) => content.push(text),
        onReasoning: (text) => reasoning.push(text),
      },
    });
    expect(content).toEqual(["甲"]);
    expect(reasoning).toEqual(["乙"]);
  });

  test("redacts the key from an HTTP error body", async () => {
    const fetchImpl: typeof fetch = async () => new Response("invalid fixture-key", { status: 401 });
    await expect(
      createBrowserTransport(fetchImpl).stream({
        url: "http://127.0.0.1:9/v1/chat/completions",
        apiKey: "fixture-key",
        body: "{}",
        signal: new AbortController().signal,
        handlers: { onContent: () => {}, onReasoning: () => {} },
      }),
    ).rejects.toThrow(/••••/);
  });
});

describe("native streaming", () => {
  test("fills a gap of dropped events from the Rust log", async () => {
    const native = fakeNative();
    const content: string[] = [];
    const done = createNativeTransport(async () => native.bridge).resume?.({
      streamId: "r",
      apiKey: "fixture-key",
      signal: new AbortController().signal,
      handlers: { onContent: (text) => content.push(text), onReasoning: () => {} },
    });
    await flush();
    native.chunk(frame("甲"));
    native.chunk(frame("乙"), false);
    native.chunk(frame("丙"), false);
    native.chunk(frame("丁"));
    native.end("done");
    await done;
    expect(content).toEqual(["甲", "乙", "丙", "丁"]);
  });

  test("catches up when the page becomes visible after missing the end", async () => {
    const native = fakeNative();
    const content: string[] = [];
    const done = createNativeTransport(async () => native.bridge).resume?.({
      streamId: "r",
      apiKey: "fixture-key",
      signal: new AbortController().signal,
      handlers: { onContent: (text) => content.push(text), onReasoning: () => {} },
    });
    await flush();
    native.chunk(frame("后台里写的"), false);
    native.end("done", "", false);
    document.dispatchEvent(new Event("visibilitychange"));
    await done;
    expect(content).toEqual(["后台里写的"]);
  });

  test("reports a stream Rust no longer knows", async () => {
    const native = fakeNative();
    native.setState("missing");
    await expect(
      createNativeTransport(async () => native.bridge).resume?.({
        streamId: "r",
        apiKey: "fixture-key",
        signal: new AbortController().signal,
        handlers: { onContent: () => {}, onReasoning: () => {} },
      }),
    ).rejects.toBeInstanceOf(StreamLostError);
  });

  test("redacts the key from a native error and cancels on abort", async () => {
    const native = fakeNative();
    const failing = createNativeTransport(async () => native.bridge).resume?.({
      streamId: "r",
      apiKey: "fixture-key",
      signal: new AbortController().signal,
      handlers: { onContent: () => {}, onReasoning: () => {} },
    });
    await flush();
    native.end("error", "流中断: fixture-key rejected");
    await expect(failing).rejects.toThrow(/••••/);

    const other = fakeNative();
    const controller = new AbortController();
    const stopped = createNativeTransport(async () => other.bridge).resume?.({
      streamId: "r",
      apiKey: "fixture-key",
      signal: controller.signal,
      handlers: { onContent: () => {}, onReasoning: () => {} },
    });
    await flush();
    controller.abort();
    await expect(stopped).rejects.toMatchObject({ name: "AbortError" });
    expect(other.calls).toContain("cancel_chat_stream");
  });
});
