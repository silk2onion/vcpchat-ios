// @vitest-environment jsdom
import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { watchAppLifecycle } from "../lifecycle";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useLogStore } from "./logs";
import { useSettingsStore } from "./settings";

class FakeSocket {
  static OPEN = 1;
  static opened: FakeSocket[] = [];
  readyState = 0;
  sent: string[] = [];
  send(text: string) { this.sent.push(text); }
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  constructor(readonly url: string) {
    FakeSocket.opened.push(this);
  }
  open() {
    this.readyState = 1;
    this.onopen?.();
  }
  close() {
    this.readyState = 3;
    this.onclose?.();
  }
}

describe("VCPLog reconnect on foreground", () => {
  beforeEach(async () => {
    vi.useFakeTimers();
    FakeSocket.opened = [];
    vi.stubGlobal("WebSocket", FakeSocket);
    setActivePinia(createPinia());
    installRepository(createMemoryRepository());
    const settings = useSettingsStore();
    await settings.load();
    await settings.patch({ logUrl: "ws://127.0.0.1:6005", logKey: "fixture" });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  test("a dropped socket reconnects right away instead of waiting out the backoff", async () => {
    const logs = useLogStore();
    await logs.sync();
    expect(FakeSocket.opened.map((socket) => socket.url)).toEqual(["ws://127.0.0.1:6005/VCPlog/VCP_Key=fixture?deviceName=VCPChat-iOS", "ws://127.0.0.1:6005/vcpinfo/VCP_Key=fixture"]);
    for (const socket of FakeSocket.opened) socket.open();
    FakeSocket.opened[0].close();
    expect(logs.status.log).toBe("已断开");

    await logs.resume(3_000);
    expect(FakeSocket.opened).toHaveLength(3);
    expect(FakeSocket.opened[2].url).toContain("/VCPlog/");
    FakeSocket.opened[2].open();
    expect(logs.status.log).toBe("已连接");

    vi.advanceTimersByTime(60_000);
    expect(FakeSocket.opened).toHaveLength(3);
  });

  test("after a long background both channels are rebuilt even if they look open", async () => {
    const logs = useLogStore();
    await logs.sync();
    for (const socket of FakeSocket.opened) socket.open();
    await logs.resume(5_000);
    expect(FakeSocket.opened).toHaveLength(2);
    await logs.resume(60_000);
    expect(FakeSocket.opened).toHaveLength(4);
  });

  test("an unconfigured log channel stays closed", async () => {
    const logs = useLogStore();
    await logs.resume(60_000);
    expect(FakeSocket.opened).toHaveLength(0);
  });
  test("preserves full structured RAG, redacts secrets and keeps pending approvals on clear", async () => {
    const logs = useLogStore(); await logs.sync();
    for (const socket of FakeSocket.opened) socket.open();
    FakeSocket.opened[1].onmessage?.({ data: JSON.stringify({ type: "RAG_RETRIEVAL_DETAILS", results: [{ text: "x".repeat(6000) + "fixture" }] }) });
    await Promise.resolve();
    expect(JSON.stringify(logs.entries[0].payload)).toContain("x".repeat(6000));
    expect(JSON.stringify(logs.entries[0].payload)).not.toContain("fixture");
    FakeSocket.opened[0].onmessage?.({ data: JSON.stringify({ type: "tool_approval_request", data: { requestId: "req1", toolName: "Read" } }) });
    await Promise.resolve();
    expect(logs.pending).toHaveLength(1);
    await logs.clear();
    expect(logs.entries).toHaveLength(1);
    expect(logs.pending).toHaveLength(1);
    await logs.disconnect();
  });

  test("sends once per request ID and waits for a remote confirmation", async () => {
    const logs = useLogStore(); await logs.sync();
    for (const socket of FakeSocket.opened) socket.open();
    const socket = FakeSocket.opened[0];
    const data = JSON.stringify({ type: "tool_approval_request", data: { requestId: "req1", toolName: "Read" } });
    socket.onmessage?.({ data }); socket.onmessage?.({ data });
    await Promise.resolve();
    expect(logs.pending).toHaveLength(1);
    const id = logs.pending[0].id;
    await logs.respond(id, true, "  只读  ");
    expect(socket.sent.map((value) => JSON.parse(value))).toEqual([{ type: "tool_approval_response", data: { requestId: "req1", approved: true, reason: "只读" } }]);
    expect(logs.approvalStatus(logs.entries[0])).toBe("sent");
    expect(logs.approvalStatus(logs.entries[1])).toBe("sent");
    await expect(logs.respond(logs.entries[1].id, false, "")).rejects.toThrow("已处理");
    socket.onmessage?.({ data: socket.sent[0] });
    await Promise.resolve();
    expect(logs.approvalStatus(logs.entries[0])).toBe("approved");
    await logs.disconnect();
  });

  test("a disconnected or expired request remains unsent", async () => {
    const logs = useLogStore(); await logs.sync();
    for (const socket of FakeSocket.opened) socket.open();
    const socket = FakeSocket.opened[0];
    socket.onmessage?.({ data: JSON.stringify({ type: "tool_approval_request", data: { requestId: "expired", expiresAt: Date.now() - 1 } }) });
    socket.onmessage?.({ data: JSON.stringify({ type: "tool_approval_request", data: { requestId: "pending" } }) });
    await Promise.resolve();
    await expect(logs.respond(logs.entries[0].id, true, "")).rejects.toThrow("已过期");
    socket.close();
    await expect(logs.respond(logs.entries[1].id, true, "")).rejects.toThrow("未连接");
    expect(logs.entries[1].decision).toBeUndefined(); expect(socket.sent).toHaveLength(0);
    await logs.disconnect();
  });

});

describe("app lifecycle", () => {
  test("reports how long the app was hidden, once per transition", () => {
    vi.useFakeTimers();
    const seen: string[] = [];
    let state: DocumentVisibilityState = "visible";
    vi.spyOn(document, "visibilityState", "get").mockImplementation(() => state);
    const stop = watchAppLifecycle({ hidden: () => seen.push("hidden"), visible: (ms) => seen.push(`visible ${ms}`) });
    state = "hidden";
    document.dispatchEvent(new Event("visibilitychange"));
    window.dispatchEvent(new Event("pagehide"));
    vi.advanceTimersByTime(25_000);
    state = "visible";
    document.dispatchEvent(new Event("visibilitychange"));
    window.dispatchEvent(new Event("pageshow"));
    stop();
    expect(seen).toEqual(["hidden", "visible 25000"]);
    vi.useRealTimers();
    vi.restoreAllMocks();
  });
});
