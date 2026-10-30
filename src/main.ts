import { createPinia } from "pinia";
import { createApp } from "vue";
import App from "./App.vue";
import { watchAppLifecycle } from "./lifecycle";
import { router } from "./router";
import { installRepository } from "./storage";
import { useLibraryStore } from "./stores/library";
import { useLogStore } from "./stores/logs";
import { useNotesStore } from "./stores/notes";
import { useSyncStore } from "./stores/sync";
import { useSettingsStore } from "./stores/settings";
import "./styles.css";
import "./polish.css";
import { installAppViewport } from "./viewport";

installAppViewport();

const app = createApp(App);
const pinia = createPinia();
app.use(pinia);
app.use(router);

async function boot() {
  installRepository();
  await useSettingsStore().load();
  const library = useLibraryStore();
  await library.load();
  await useNotesStore().load();
  const logs = useLogStore();
  await logs.load();
  void logs.sync();
  watchAppLifecycle({
    hidden: () => { useSyncStore().cancel(); void library.flushStreams(); },
    visible: (hiddenForMs) => void logs.resume(hiddenForMs),
  });
  void library.recoverStreams();
  app.mount("#app");
}

boot().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "应用没有启动";
  const root = document.querySelector("#app");
  if (root) root.textContent = message;
});
