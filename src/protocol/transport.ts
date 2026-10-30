import { isTauri } from "./http";
import { redactSecrets } from "./redact";
import { createSseParser, extractSseJson } from "./sse";

export interface ChatStreamHandlers {
  onContent: (text: string) => void;
  onReasoning: (text: string) => void;
  /** Called before any content when the stream outlives the page and can be re-attached by id. */
  onStreamId?: (id: string) => void;
}

export interface ChatTransport {
  stream(options: {
    url: string;
    apiKey: string;
    body: string;
    signal: AbortSignal;
    handlers: ChatStreamHandlers;
  }): Promise<void>;
  /** Replays a stream started earlier, from its first chunk, and follows it to the end. */
  resume?(options: { streamId: string; apiKey: string; signal: AbortSignal; handlers: ChatStreamHandlers }): Promise<void>;
  release?(streamId: string): Promise<void>;
}

/** The stream is gone, for example because the app was restarted while it was running. */
export class StreamLostError extends Error {
  constructor() {
    super("流式连接已经不在了");
    this.name = "StreamLostError";
  }
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

interface NativeStreamEvent {
  requestId: string;
  kind: string;
  text: string;
  seq: number;
}

interface NativeSnapshot {
  fromSeq: number;
  chunks: string[];
  state: "running" | "done" | "error" | "cancelled" | "missing";
  error: string;
}

export interface NativeBridge {
  invoke<T>(command: string, args: Record<string, unknown>): Promise<T>;
  listen(handler: (event: NativeStreamEvent) => void): Promise<() => void>;
}

async function tauriBridge(): Promise<NativeBridge> {
  const [{ invoke }, { listen }] = await Promise.all([import("@tauri-apps/api/core"), import("@tauri-apps/api/event")]);
  return {
    invoke: (command, args) => invoke(command, args),
    listen: (handler) => listen<NativeStreamEvent>("vcp-stream", (event) => handler(event.payload)),
  };
}

const POLL_MS = 3000;

/**
 * Follows a stream held in Rust. Events carry a sequence number; a gap, a timer or the page
 * becoming visible again pulls the missing chunks from the Rust log, so nothing is lost while
 * the WebView was suspended.
 */
async function followNativeStream(options: {
  bridge: NativeBridge;
  requestId: string;
  apiKey: string;
  signal: AbortSignal;
  handlers: ChatStreamHandlers;
  start?: () => Promise<void>;
}): Promise<void> {
  const { bridge, requestId, apiKey, signal, handlers } = options;
  let nextSeq = 0;
  let failed = "";
  let ended: { state: string; error: string; total: number } | null = null;
  const finished = () => ended !== null && nextSeq >= ended.total;
  let wake = () => {};
  const parser = createSseParser({
    onContent: handlers.onContent,
    onReasoning: handlers.onReasoning,
    onError(message) {
      failed = message;
    },
    onDone() {},
  });
  const take = (seq: number, text: string) => {
    if (seq !== nextSeq) return;
    parser.push(text);
    nextSeq += 1;
  };
  let syncing: Promise<void> | null = null;
  const sync = () => {
    syncing ??= bridge
      .invoke<NativeSnapshot>("chat_stream_snapshot", { requestId, fromSeq: nextSeq })
      .then((snapshot) => {
        snapshot.chunks.forEach((chunk, index) => take(snapshot.fromSeq + index, chunk));
        if (snapshot.state !== "running") ended = { state: snapshot.state, error: snapshot.error, total: snapshot.fromSeq + snapshot.chunks.length };
      })
      .catch(() => undefined)
      .finally(() => {
        syncing = null;
        wake();
      });
    return syncing;
  };
  const unlisten = await bridge.listen((event) => {
    if (event.requestId !== requestId) return;
    if (event.kind === "chunk") {
      if (event.seq === nextSeq) take(event.seq, event.text);
      else if (event.seq > nextSeq) void sync();
    } else {
      ended = { state: event.kind, error: event.text, total: event.seq };
      if (event.seq > nextSeq) void sync();
    }
    wake();
  });
  const onVisible = () => {
    if (typeof document === "undefined" || document.visibilityState === "visible") void sync();
  };
  if (typeof document !== "undefined") document.addEventListener("visibilitychange", onVisible);
  const onAbort = () => {
    void bridge.invoke("cancel_chat_stream", { requestId }).catch(() => undefined);
    wake();
  };
  signal.addEventListener("abort", onAbort, { once: true });
  try {
    if (options.start) await options.start();
    else await sync();
    while (!finished() && !signal.aborted) {
      const woke = await new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), POLL_MS);
        wake = () => {
          clearTimeout(timer);
          resolve(true);
        };
      });
      if (!woke) await sync();
    }
    if (signal.aborted) throw new DOMException("已停止", "AbortError");
    const end = ended as { state: string; error: string; total: number } | null;
    if (!end) throw new StreamLostError();
    parser.finish();
    if (end.state === "missing") throw new StreamLostError();
    if (end.state === "cancelled") throw new DOMException("已停止", "AbortError");
    if (end.state === "error") throw new Error(redactSecrets(end.error || "流式请求失败", [apiKey]));
    if (failed) throw new Error(redactSecrets(failed, [apiKey]));
  } finally {
    signal.removeEventListener("abort", onAbort);
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", onVisible);
    unlisten();
  }
}

export function createNativeTransport(bridgeFactory: () => Promise<NativeBridge> = tauriBridge): ChatTransport {
  return {
    async stream({ url, apiKey, body, signal, handlers }) {
      const bridge = await bridgeFactory();
      const requestId = crypto.randomUUID();
      handlers.onStreamId?.(requestId);
      await followNativeStream({
        bridge,
        requestId,
        apiKey,
        signal,
        handlers,
        start: () => bridge.invoke("start_chat_stream", { requestId, url, apiKey, body }),
      });
    },
    async resume({ streamId, apiKey, signal, handlers }) {
      const bridge = await bridgeFactory();
      await followNativeStream({ bridge, requestId: streamId, apiKey, signal, handlers });
    },
    async release(streamId) {
      const bridge = await bridgeFactory();
      await bridge.invoke("release_chat_stream", { requestId: streamId }).catch(() => undefined);
    },
  };
}
