import { createRouter, createWebHashHistory } from "vue-router";
import ChatView from "./views/ChatView.vue";
import LogsView from "./views/LogsView.vue";
import NotesView from "./views/NotesView.vue";
import SettingsView from "./views/SettingsView.vue";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", component: ChatView },
    { path: "/notes", component: NotesView },
    { path: "/logs", component: LogsView },
    { path: "/settings", component: SettingsView },
  ],
});
