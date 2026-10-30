// @vitest-environment jsdom
import { createApp, h, nextTick, ref } from "vue";
import { createPinia, setActivePinia } from "pinia";
import { afterEach, expect, test, vi } from "vitest";
import ModelField from "./ModelField.vue";
import { useSettingsStore } from "../stores/settings";
import { useModelStore } from "../stores/models";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
const request = vi.hoisted(() => vi.fn());
vi.mock("../protocol/http", () => ({ createAppHttp: async () => ({ request }) }));
const apps: ReturnType<typeof createApp>[] = [];
afterEach(() => { apps.splice(0).forEach((app) => app.unmount()); document.body.innerHTML = ""; request.mockReset(); });
async function settle() { for (let i = 0; i < 8; i++) { await nextTick(); await Promise.resolve(); } }
async function mount(inherit = false, cached = true) {
  const pinia = createPinia(); setActivePinia(pinia); installRepository(createMemoryRepository());
  const settings = useSettingsStore(); await settings.load();
  const ids = Array.from({ length: 380 }, (_, i) => `Provider/Model-${String(i).padStart(3, "0")}:free`);
  await settings.patch({ serverUrl: "http://localhost:43128", apiKey: "fixture", defaultModel: "global", modelCatalog: cached ? { endpoint: "http://localhost:43128/v1/models", ids, recent: [], updatedAt: Date.now() } : null });
  const value = ref(""); const commit = vi.fn(); const escaped = vi.fn();
  const host = document.createElement("div"); document.body.append(host);
  const app = createApp({ render: () => h("div", { onKeydown: (e: KeyboardEvent) => { if (e.key === "Escape") escaped(); } }, h(ModelField, { label: "模型", modelValue: value.value, "onUpdate:modelValue": (next: string) => value.value = next, onCommit: commit, inherit, inheritedModel: "global" })) });
  app.use(pinia); apps.push(app); app.mount(host); await settle();
  const open = async () => { host.querySelector<HTMLButtonElement>('[aria-label="选择模型"]')!.click(); await settle(); };
  const search = async (query: string) => { const input = host.querySelector<HTMLInputElement>('[role="combobox"]')!; input.value = query; input.dispatchEvent(new Event("input", { bubbles: true })); await settle(); return input; };
  return { host, open, search, ids, value, commit, escaped };
}
test("380 cached IDs mount at most 12 option rows, scroll to the last ID, and select its exact ID", async () => {
  const { host, open, ids, value } = await mount(); await open();
  expect(request).not.toHaveBeenCalled(); expect(host.querySelectorAll('[role="option"]').length).toBeLessThanOrEqual(12);
  const list = host.querySelector<HTMLElement>('[role="listbox"]')!; list.scrollTop = 380 * 52 - 312; list.dispatchEvent(new Event("scroll")); await settle();
  const last = [...host.querySelectorAll<HTMLButtonElement>('[role="option"]')].find((row) => row.title === ids[379]);
  expect(last).toBeDefined(); last!.click(); await settle(); expect(value.value).toBe(ids[379]);
  expect(host.querySelector('[role="listbox"]')).toBeNull();
});
test("case-insensitive token search, keyboard selection, IME and two-level Escape work without blocking the parent", async () => {
  const { host, open, search, ids, value, escaped } = await mount(); await open();
  const input = await search("provider 237"); expect(host.querySelectorAll('[role="option"]')).toHaveLength(1);
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true, cancelable: true })); expect(value.value).toBe("");
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })); await settle(); expect(value.value).toBe(ids[237]);
  await open(); input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  host.querySelector<HTMLInputElement>('[role="combobox"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); await settle();
  expect(escaped).not.toHaveBeenCalled(); expect(host.querySelector('[role="listbox"]')).toBeNull();
  host.querySelector('input')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); expect(escaped).toHaveBeenCalledTimes(1);
});
test("manual IDs, recent selection and agent inheritance retain their existing meanings", async () => {
  const { host, open, ids, value, commit } = await mount(true);
  const manual = host.querySelector<HTMLInputElement>('input')!; manual.value = "My/Unlisted:ID"; manual.dispatchEvent(new Event("input", { bubbles: true })); manual.dispatchEvent(new Event("change", { bubbles: true })); await settle();
  expect(value.value).toBe("My/Unlisted:ID"); expect(commit).toHaveBeenCalledWith("My/Unlisted:ID");
  await useModelStore().remember(ids[379]); await open(); expect(host.querySelector('[role="option"]')?.textContent).toContain(ids[379]);
  host.querySelector<HTMLButtonElement>('.model-inherit')!.click(); await settle(); expect(value.value).toBe(""); expect(useSettingsStore().settings.defaultModel).toBe("global");
});
test("cold network delays never block opening, typing a filter or closing the chooser", async () => {
  request.mockImplementation(() => new Promise(() => {})); const { host, open, search } = await mount(false, false);
  await open(); expect(host.querySelector('[role="combobox"]')).not.toBeNull(); await search("anything");
  expect(request).toHaveBeenCalledTimes(1); host.querySelector<HTMLButtonElement>('[aria-label="选择模型"]')!.click(); await settle(); expect(host.querySelector('[role="combobox"]')).toBeNull();
});
