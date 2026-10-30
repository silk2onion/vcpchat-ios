import { createPinia, setActivePinia } from "pinia";
import { beforeEach, expect, test, vi } from "vitest";
import { defaultSettings } from "../domain";
import { listModels } from "../protocol/models";
import { installRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "./settings";
import { useModelStore } from "./models";
const request = vi.hoisted(() => vi.fn());
vi.mock("../protocol/http", async (original) => ({ ...await original<typeof import("../protocol/http")>(), createAppHttp: async () => ({ request }) }));
const response = (ids: string[]) => ({ status: 200, body: JSON.stringify({ data: ids.map((id) => ({ id })) }) });
beforeEach(async () => {
  setActivePinia(createPinia()); installRepository(createMemoryRepository()); request.mockReset();
  await useSettingsStore().load(); await useSettingsStore().patch({ serverUrl: "http://localhost:43128", apiKey: "fixture-secret" });
});
test("deduplicates concurrent reads, persists the catalog across a new app store, and refreshes only on request", async () => {
  const store = useModelStore(); request.mockResolvedValue(response(["provider/A", "provider/B"]));
  await Promise.all([store.ensure(), store.ensure()]); expect(request).toHaveBeenCalledTimes(1);
  await store.remember("provider/B");
  setActivePinia(createPinia()); await useSettingsStore().load();
  const reopened = useModelStore(); expect(await reopened.ensure()).toEqual(["provider/A", "provider/B"]);
  expect(reopened.recent).toEqual(["provider/B"]); expect(request).toHaveBeenCalledTimes(1);
  request.mockResolvedValue(response(["provider/C"])); await reopened.ensure(true);
  expect(reopened.ids).toEqual(["provider/C"]); expect(reopened.recent).toEqual([]); expect(request).toHaveBeenCalledTimes(2);
});
test("a failed refresh keeps cached choices and redacts credentials", async () => {
  const store = useModelStore(); request.mockResolvedValue(response(["kept"])); await store.ensure();
  request.mockRejectedValue(new Error("bad fixture-secret")); await expect(store.ensure(true)).rejects.toThrow();
  expect(store.ids).toEqual(["kept"]); expect(store.error).not.toContain("fixture-secret"); expect(store.loading).toBe(false);
});
test("changing credentials through the real form mutation pattern invalidates cache without changing the chosen model", async () => {
  const settings = useSettingsStore(); const store = useModelStore(); request.mockResolvedValue(response(["old"])); await store.ensure();
  await settings.patch({ defaultModel: "manual/custom-model" });
  settings.settings.apiKey = "new-key"; await settings.patch({ apiKey: settings.settings.apiKey });
  expect(store.ids).toEqual([]); expect(settings.settings.defaultModel).toBe("manual/custom-model");
  request.mockResolvedValue(response(["new"])); await store.ensure();
  await settings.patch({ serverUrl: "http://other.local:6005" }); expect(store.ids).toEqual([]);
});
test("a delayed response from the previous server cannot overwrite a new catalog", async () => {
  let finish!: (value: ReturnType<typeof response>) => void;
  request.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
  const store = useModelStore(); const old = store.ensure(); const rejected = expect(old).rejects.toThrow("连接信息已改变");
  await vi.waitFor(() => expect(request).toHaveBeenCalledTimes(1));
  await useSettingsStore().patch({ serverUrl: "http://new.local:6005" }); request.mockResolvedValue(response(["new"]));
  await store.ensure(); finish(response(["old"])); await rejected;
  expect(store.ids).toEqual(["new"]); expect(store.error).toBe(""); expect(store.loading).toBe(false);
});
test("model parsing preserves complete literal IDs and server order while removing duplicates and empty IDs", async () => {
  const ids = ["provider/Case-Sensitive:free", "very/long/Model ID:0.2", "provider/Case-Sensitive:free", "", "   "];
  request.mockResolvedValue({ status: 200, body: JSON.stringify({ data: [...ids.map((id) => ({ id })), { id: 12 }, {}] }) });
  expect(await listModels({ ...defaultSettings(), serverUrl: "http://localhost", apiKey: "fixture" }, { request })).toEqual(ids.slice(0, 2));
});
