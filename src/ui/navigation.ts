import { useRouter } from "vue-router";
import type { OwnerType } from "../domain";
import { useLibraryStore } from "../stores/library";

export const primaryTabs = [
  { to: "/", label: "会话", icon: "chat" },
  { to: "/agents", label: "通讯录", icon: "agents" },
  { to: "/me", label: "我", icon: "person" },
];

export function tabIsActive(tab: string, path: string): boolean {
  if (tab === "/") return path === "/" || path.startsWith("/chat/") || path === "/chat";
  if (tab === "/me") return path === "/me" || path === "/notes" || path === "/logs" || path === "/settings" || path.startsWith("/settings/");
  return path === tab;
}

export function pageTransition(next: string, previous: string): string {
  if ((next === "/" && tabIsActive("/", previous)) || (next === "/me" && previous !== "/me" && tabIsActive("/me", previous)) || (next === "/settings" && (previous.startsWith("/settings/") || previous === "/logs"))) return "page-back";
  if (next.startsWith("/chat") || next === "/notes" || next === "/logs" || next.startsWith("/settings")) return "page-forward";
  return "page-tab";
}

export function useChatNavigation() {
  const router = useRouter();
  const library = useLibraryStore();
  const show = () => router.push(`/chat/${encodeURIComponent(library.topicId)}`);
  async function openTopic(id: string) { await library.selectTopic(id); await show(); }
  async function openOwner(type: OwnerType, id: string) { await library.selectOwner(type, id); await show(); }
  async function newChat(type: OwnerType, id: string) { await library.createTopicFor(type, id); await show(); }
  return { openTopic, openOwner, newChat };
}

export function shortDate(timestamp: number): string {
  const date = new Date(timestamp);
  const now = new Date();
  return date.toDateString() === now.toDateString()
    ? date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })
    : date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}
