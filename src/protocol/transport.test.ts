import { describe, expect, test } from "vitest";
import { createBrowserTransport } from "./transport";

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
