// @vitest-environment jsdom
import { createApp, nextTick } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { createMemoryHistory, createRouter } from "vue-router";
import { expect, test, vi } from "vitest";
import ChatView from "../views/ChatView.vue";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
import { useLibraryStore } from "../stores/library";
import { setChatTransport, type ChatTransport } from "../protocol/transport";

test("the real composer changes Enter behavior immediately and leaves IME/Shift confirmation alone", async () => {
  const pinia = createPinia(); setActivePinia(pinia); installRepository(createMemoryRepository());
  const settings = useSettingsStore(); await settings.load();
  await settings.patch({ serverUrl: "http://127.0.0.1:9", apiKey: "fixture", defaultModel: "demo" });
  const library = useLibraryStore(); await library.load();
  const stream = vi.fn<ChatTransport["stream"]>().mockImplementation(async ({ handlers }) => { handlers.onContent("已收到"); });
  setChatTransport({ stream });
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => window.setTimeout(callback, 0));
  vi.stubGlobal("cancelAnimationFrame", (id: number) => window.clearTimeout(id));
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/chat/:topicId", component: ChatView }] });
  await router.push("/chat/" + library.topicId); await router.isReady();
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp(ChatView); app.use(pinia); app.use(router); app.mount(host); await nextTick();
  const input = host.querySelector("textarea")!;
  const fill = async (value: string) => { input.value = value; input.dispatchEvent(new Event("input", { bubbles: true })); await nextTick(); };
  const key = (options: KeyboardEventInit = {}) => { const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true, ...options }); input.dispatchEvent(event); return event; };
  try {
    await fill("换行模式"); expect(key().defaultPrevented).toBe(false); expect(stream).not.toHaveBeenCalled();
    await settings.patch({ enterSends: true }); await nextTick();
    expect(input.getAttribute("enterkeyhint")).toBe("send");
    expect(key({ isComposing: true }).defaultPrevented).toBe(false);
    expect(key({ keyCode: 229 }).defaultPrevented).toBe(false);
    expect(key({ shiftKey: true }).defaultPrevented).toBe(false); expect(stream).not.toHaveBeenCalled();
    expect(key().defaultPrevented).toBe(true);
    await vi.waitFor(() => expect(library.messages.at(-1)?.content).toBe("已收到"));
    expect(stream).toHaveBeenCalledTimes(1);
    await settings.patch({ enterSends: false }); await nextTick(); await fill("快捷键发送");
    expect(key({ ctrlKey: true }).defaultPrevented).toBe(true);
    await vi.waitFor(() => expect(stream).toHaveBeenCalledTimes(2));
  } finally { app.unmount(); host.remove(); setChatTransport(null); vi.unstubAllGlobals(); }
});
