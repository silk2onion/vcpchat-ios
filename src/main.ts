import { createPinia } from "pinia";
import { createApp } from "vue";
import App from "./App.vue";
import { router } from "./router";
import { installRepository } from "./storage";
import { useLibraryStore } from "./stores/library";
import { useLogStore } from "./stores/logs";
import { useNotesStore } from "./stores/notes";
import { useSettingsStore } from "./stores/settings";
import "./styles.css";

const app = createApp(App);
const pinia = createPinia();
app.use(pinia);
app.use(router);

async function boot() {
  installRepository();
  await useSettingsStore().load();
  await useLibraryStore().load();
  await useNotesStore().load();
  await useLogStore().load();
  app.mount("#app");
}

boot().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "应用没有启动";
  const root = document.querySelector("#app");
  if (root) root.textContent = message;
});
