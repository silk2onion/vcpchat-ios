// @vitest-environment jsdom
import { createApp, nextTick, h, ref } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { createMemoryHistory, createRouter } from "vue-router";
import { afterEach, expect, test, vi } from "vitest";
const request = vi.hoisted(() => vi.fn());
vi.mock("../protocol/http", async (original) => ({ ...await original<typeof import("../protocol/http")>(), createAppHttp: async () => ({ request }) }));
import SettingsView from "../views/SettingsView.vue";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "../stores/settings";
const apps: ReturnType<typeof createApp>[] = [];
afterEach(() => { for (const app of apps.splice(0)) app.unmount(); document.body.innerHTML = ""; request.mockReset(); });
async function settle() { for (let i = 0; i < 10; i++) { await nextTick(); await Promise.resolve(); } }
test("reopening the real settings model chooser keeps 360 cached IDs without waiting on the network", async () => {
  const pinia = createPinia(); setActivePinia(pinia); installRepository(createMemoryRepository());
  const settings = useSettingsStore(); await settings.load(); await settings.patch({ serverUrl: "http://127.0.0.1:43128", apiKey: "fixture" });
  const ids = Array.from({ length: 360 }, (_, i) => `provider/model-${String(i).padStart(3, "0")}`);
  request.mockResolvedValue({ status: 200, body: JSON.stringify({ data: ids.map((id) => ({ id })) }) });
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: "/settings/:section?", component: SettingsView }, { path: "/logs", component: { render: () => null } }] });
  await router.push("/settings/connection"); await router.isReady();
  const show = ref(true);
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp({ render: () => show.value ? h(SettingsView) : null });
  app.use(pinia); app.use(router); apps.push(app); app.mount(host); await settle();
  host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })); await settle();
  expect(request).toHaveBeenCalledTimes(1); expect(settings.settings.defaultModel).toBe(ids[0]);
  show.value = false; await settle();
  request.mockImplementation(() => new Promise(() => {}));
  show.value = true; await settle();
  const choose = host.querySelector<HTMLButtonElement>('button[aria-label="选择默认模型"]');
  if (choose) choose.click(); else host.querySelector<HTMLInputElement>('input[list="model-options"]')?.focus();
  await settle();
  const choices = [...document.querySelectorAll('datalist option, [role="option"]')].map((node) => node.getAttribute("value") || node.textContent);
  expect(choices.some((value) => value?.includes(ids[0]))).toBe(true);
  expect(request).toHaveBeenCalledTimes(1);
});
