import { defineStore } from "pinia";
import { onScopeDispose, ref } from "vue";
import type { Attachment } from "../domain";

export type WorkspaceSheet =
  | { type: "new-chat" }
  | { type: "agent"; id?: string }
  | { type: "group"; id?: string }
  | { type: "main-agent" }
  | { type: "topics" }
  | { type: "topic-options"; id: string };

export const useWorkspaceStore = defineStore("workspace", () => {
  const sheet = ref<WorkspaceSheet | null>(null);
  const closing = ref(false);
  const activityOpen = ref(false);
  const activityClosing = ref(false);
  const activityTab = ref<"notifications" | "log" | "rag">("notifications");
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  let activityTimer: ReturnType<typeof setTimeout> | undefined;
  const drafts = ref<
    Record<string, { text: string; attachments: Attachment[] }>
  >({});

  function draftFor(topicId: string) {
    return drafts.value[topicId] ?? { text: "", attachments: [] };
  }
  function saveDraft(
    topicId: string,
    partial: Partial<ReturnType<typeof draftFor>>,
  ) {
    if (topicId) drafts.value[topicId] = { ...draftFor(topicId), ...partial };
  }
  function clearDraft(topicId: string) {
    delete drafts.value[topicId];
  }
  function open(next: WorkspaceSheet) {
    clearTimeout(closeTimer); closing.value = false;
    sheet.value = next;
  }
  function close() {
    closing.value = true;
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => { sheet.value = null; closing.value = false; }, 180);
  }
  function openActivity(tab: typeof activityTab.value = "notifications") { clearTimeout(activityTimer); activityClosing.value = false; activityTab.value = tab; activityOpen.value = true; }
  function closeActivity() { activityClosing.value = true; clearTimeout(activityTimer); activityTimer = setTimeout(() => { activityOpen.value = false; activityClosing.value = false; }, 180); }
  onScopeDispose(() => { clearTimeout(closeTimer); clearTimeout(activityTimer); });
  return { sheet, closing, activityOpen, activityClosing, activityTab, drafts, draftFor, saveDraft, clearDraft, open, close, openActivity, closeActivity };
});
