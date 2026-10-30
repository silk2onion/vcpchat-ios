import { useRouter } from "vue-router";
import type { OwnerType } from "../domain";
import { useLibraryStore } from "../stores/library";

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
