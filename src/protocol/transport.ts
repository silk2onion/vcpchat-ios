import { isTauri } from "./http";
import { redactSecrets } from "./redact";
import { createSseParser, extractSseJson } from "./sse";

export interface ChatStreamHandlers {
  onContent: (text: string) => void;
  onReasoning: (text: string) => void;
}

export interface ChatTransport {
  stream(options: {
    url: string;
    apiKey: string;
    body: string;
    signal: AbortSignal;
    handlers: ChatStreamHandlers;
  }): Promise<void>;
}

let overrideTransport: ChatTransport | null = null;

export function setChatTransport(transport: ChatTransport | null) {
  overrideTransport = transport;
}

export function getChatTransport(): ChatTransport {
  if (overrideTransport) return overrideTransport;
  return isTauri() ? createNativeTransport() : createBrowserTransport();
}

export function createBrowserTransport(fetchImpl: typeof fetch = fetch): ChatTransport {
  return {
    async stream({ url, apiKey, body, signal, handlers }) {
      const secrets = [apiKey];
      let response: Response;
      try {
        response = await fetchImpl(url, {
          method: "POST",
          signal,
          headers: {
            "Content-Type": "application/json",
            Accept: "text/event-stream, application/json",
            Authorization: `Bearer ${apiKey}`,
          },
          body,
        });
      } catch (error) {
        if (signal.aborted) throw error;
        const message = error instanceof Error ? error.message : "网络请求失败";
        throw new Error(redactSecrets(message, secrets));
      }
      if (!response.ok) {
        const text = await response.text();
        throw new Error(redactSecrets(formatStatus(response.status, text), secrets));
      }
      const contentType = response.headers.get("content-type") ?? "";
      if (!contentType.includes("text/event-stream")) {
        const text = await response.text();
        if (text.trimStart().startsWith("data:")) {
          consumeSse(text, handlers);
          return;
        }
        let parsed: unknown;
        try {
          parsed = JSON.parse(text);
        } catch {
          throw new Error("服务器没有返回可识别的流或 JSON");
        }
        const delta = extractSseJson(parsed);
        if (delta.error) throw new Error(redactSecrets(delta.error, secrets));
        if (delta.reasoning) handlers.onReasoning(delta.reasoning);
        if (delta.content) handlers.onContent(delta.content);
        return;
      }
      if (!response.body) throw new Error("响应没有正文");
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let failed = "";
      const parser = createSseParser({
        onContent: handlers.onContent,
        onReasoning: handlers.onReasoning,
        onError(message) {
          failed = message;
        },
        onDone() {},
      });
      try {
        while (!signal.aborted) {
          const chunk = await reader.read();
          if (chunk.done) break;
          parser.push(decoder.decode(chunk.value, { stream: true }));
          if (failed) throw new Error(redactSecrets(failed, secrets));
        }
        parser.push(decoder.decode());
        parser.finish();
        if (failed) throw new Error(redactSecrets(failed, secrets));
        if (signal.aborted) throw new DOMException("已停止", "AbortError");
      } finally {
        reader.releaseLock();
      }
    },
  };
}

function consumeSse(text: string, handlers: ChatStreamHandlers) {
  let failed = "";
  const parser = createSseParser({
    onContent: handlers.onContent,
    onReasoning: handlers.onReasoning,
    onError(message) {
      failed = message;
    },
    onDone() {},
  });
  parser.push(text);
  parser.finish();
  if (failed) throw new Error(failed);
}

function formatStatus(status: number, body: string): string {
  const compact = body.replace(/\s+/g, " ").trim().slice(0, 300);
  return compact ? `HTTP ${status}：${compact}` : `HTTP ${status}`;
}

export function createNativeTransport(): ChatTransport {
  return {
    async stream({ url, apiKey, body, signal, handlers }) {
      const [{ invoke }, { listen }] = await Promise.all([import("@tauri-apps/api/core"), import("@tauri-apps/api/event")]);
      const requestId = crypto.randomUUID();
      let failed = "";
      let settled = false;
      const parser = createSseParser({
        onContent: handlers.onContent,
        onReasoning: handlers.onReasoning,
        onError(message) {
          failed = message;
        },
        onDone() {
          settled = true;
        },
      });
      const unlisten = await listen<{ requestId: string; kind: string; text: string }>("vcp-stream", (event) => {
        if (event.payload.requestId !== requestId) return;
        if (event.payload.kind === "chunk") parser.push(event.payload.text);
        if (event.payload.kind === "error") failed = event.payload.text || "流式请求失败";
        if (event.payload.kind === "done" || event.payload.kind === "cancelled") settled = true;
      });
      const onAbort = () => {
        void invoke("cancel_chat_stream", { requestId });
      };
      signal.addEventListener("abort", onAbort, { once: true });
      try {
        await invoke("start_chat_stream", { requestId, url, apiKey, body });
        await waitUntil(() => settled || Boolean(failed) || signal.aborted, signal);
        parser.finish();
        if (signal.aborted) throw new DOMException("已停止", "AbortError");
        if (failed) throw new Error(redactSecrets(failed, [apiKey]));
      } finally {
        signal.removeEventListener("abort", onAbort);
        unlisten();
      }
    },
  };
}

function waitUntil(predicate: () => boolean, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      }
    }, 30);
    signal.addEventListener(
      "abort",
      () => {
        clearInterval(timer);
        resolve();
      },
      { once: true },
    );
  });
}
