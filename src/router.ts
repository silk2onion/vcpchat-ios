import { createRouter, createWebHashHistory } from "vue-router";
import ChatView from "./views/ChatView.vue";
import LogsView from "./views/LogsView.vue";
import NotesView from "./views/NotesView.vue";
import SettingsView from "./views/SettingsView.vue";
import ChatsView from "./views/ChatsView.vue";
import AgentsView from "./views/AgentsView.vue";
import SyncView from "./views/SyncView.vue";
import FilesView from "./views/FilesView.vue";
import MeView from "./views/MeView.vue";

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: "/", component: ChatsView },
    { path: "/chat/:topicId?", component: ChatView },
    { path: "/agents", component: AgentsView },
    { path: "/sync", component: SyncView },
    { path: "/files", component: FilesView },
    { path: "/me", component: MeView },
    { path: "/notes", component: NotesView },
    { path: "/logs", component: LogsView },
    { path: "/settings/:section?", component: SettingsView },
  ],
});
