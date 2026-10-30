// @vitest-environment jsdom
import { createApp, h, nextTick } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { createMemoryHistory, createRouter } from "vue-router";
import { expect, test, vi } from "vitest";
import App from "../App.vue";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
import { useLibraryStore } from "../stores/library";

test("route motion has a real element even when the home view has mobile and desktop roots", async () => {
  const pinia = createPinia(); setActivePinia(pinia); installRepository(createMemoryRepository());
  await useSettingsStore().load(); await useLibraryStore().load();
  vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => window.setTimeout(callback, 0));
  const warnings = vi.spyOn(console, "warn").mockImplementation(() => {});
  const home = { render: () => [h("section", "手机入口"), h("section", "桌面入口")] };
  const detail = { render: () => h("section", "会话详情") };
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/", component: home }, { path: "/chat/:id", component: detail }, ...["agents", "notes", "settings", "me", "sync", "files"].map((path) => ({ path: `/${path}`, component: detail }))] });
  await router.push("/"); await router.isReady();
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp(App); app.use(pinia); app.use(router); app.mount(host); await nextTick();
  expect(host.querySelector(".route-surface")?.children).toHaveLength(2);
  await router.push("/chat/topic_default"); await nextTick();
  await new Promise((resolve) => setTimeout(resolve, 30)); await nextTick();
  expect(host.querySelector(".route-surface")?.textContent).toContain("会话详情");
  expect(warnings.mock.calls.flat().join(" ")).not.toContain("cannot be animated");
  app.unmount(); host.remove(); warnings.mockRestore(); vi.unstubAllGlobals();
});
