import { computed, ref, watch } from "vue";
import { defineStore } from "pinia";
import { resolveModelsEndpoint } from "../protocol/endpoint";
import { createAppHttp } from "../protocol/http";
import { listModels } from "../protocol/models";
import { secretsOf } from "../domain";
import { redactSecrets } from "../protocol/redact";
import { useSettingsStore } from "./settings";

export const useModelStore = defineStore("models", () => {
  const settings = useSettingsStore();
  const loading = ref(false);
  const error = ref("");
  let pending: { source: string; promise: Promise<string[]> } | null = null;
  const endpoint = computed(() => { try { return resolveModelsEndpoint(settings.settings.serverUrl); } catch { return ""; } });
  const catalog = computed(() => settings.settings.modelCatalog?.endpoint === endpoint.value ? settings.settings.modelCatalog : null);
  const ids = computed(() => catalog.value?.ids ?? []);
  const recent = computed(() => catalog.value?.recent ?? []);
  // The credential is used only for in-flight identity; it is never duplicated into the cache.
  const source = () => `${endpoint.value}\0${settings.settings.apiKey}`;
  watch(() => [settings.settings.serverUrl, settings.settings.apiKey], () => { loading.value = false; error.value = ""; }, { flush: "sync" });

  async function ensure(force = false): Promise<string[]> {
    if (!force && ids.value.length) return ids.value;
    const ownSource = source();
    if (pending?.source === ownSource) return pending.promise;
    const snapshot = { ...settings.settings };
    loading.value = true; error.value = "";
    const promise = (async () => {
      try {
        const models = await listModels(snapshot, await createAppHttp());
        if (source() !== ownSource) throw new Error("连接信息已改变，请重新刷新模型列表");
        await settings.patch({ modelCatalog: { endpoint: resolveModelsEndpoint(snapshot.serverUrl), ids: models, updatedAt: Date.now(), recent: recent.value.filter((id) => models.includes(id)).slice(0, 8) } });
        return models;
      } catch (caught) {
        const message = redactSecrets(caught instanceof Error ? caught.message : String(caught), secretsOf(snapshot));
        if (source() === ownSource) error.value = message;
        throw new Error(message);
      } finally {
        if (pending?.source === ownSource) { pending = null; loading.value = false; }
      }
    })();
    pending = { source: ownSource, promise };
    return promise;
  }

  async function remember(id: string) {
    const current = catalog.value;
    if (!current || !id.trim()) return;
    await settings.patch({ modelCatalog: { ...current, recent: [id, ...current.recent.filter((item) => item !== id)].slice(0, 8) } });
  }
  return { ids, recent, catalog, loading, error, ensure, remember };
});
