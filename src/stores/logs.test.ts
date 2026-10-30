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
