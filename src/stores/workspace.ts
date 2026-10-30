import { defineStore } from "pinia";
import { ref } from "vue";
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
    sheet.value = next;
  }
  function close() {
    sheet.value = null;
  }
  return { sheet, drafts, draftFor, saveDraft, clearDraft, open, close };
});
