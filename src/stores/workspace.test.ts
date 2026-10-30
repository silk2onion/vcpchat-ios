import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { installRepository, getRepository } from "../storage";
import { createMemoryRepository } from "../storage/memory";
import { useSettingsStore } from "./settings";
import { useLibraryStore } from "./library";
import { useWorkspaceStore } from "./workspace";

async function load() {
  await useSettingsStore().load();
  const library = useLibraryStore();
  await library.load();
  return library;
}
beforeEach(() => {
  setActivePinia(createPinia());
  installRepository(createMemoryRepository());
});
describe("multi-agent workspace", () => {
  test("changing the main agent preserves existing owners and persists across restarts", async () => {
    const library = await load();
    const oldTopic = library.topicId;
    const original = library.ownerId;
    await getRepository().saveMessage({
      id: "old",
      topicId: oldTopic,
      role: "user",
      content: "保留我的对话",
      reasoning: "",
      attachments: [],
      createdAt: 1,
      status: "complete",
    });
    await library.createAgent("研究助理");
    const next = library.ownerId;
    await library.setMainAgent(next);
    expect(library.mainAgent?.id).toBe(next);
    expect(library.topics.find((t) => t.id === oldTopic)?.ownerId).toBe(
      original,
    );
    expect((await getRepository().listMessages(oldTopic))[0].content).toBe(
      "保留我的对话",
    );
    setActivePinia(createPinia());
    const reopened = await load();
    expect(reopened.mainAgent?.id).toBe(next);
    expect(reopened.ownerId).toBe(next);
    expect(useSettingsStore().settings.mainAgentId).toBe(next);
  });
  test("setting a main agent does not move the open conversation", async () => {
    const library = await load();
    const first = library.ownerId;
    await library.createAgent("工程助手");
    const open = library.topicId;
    await library.setMainAgent(first);
    expect(library.topicId).toBe(open);
    await library.setMainAgent("missing");
    expect(library.mainAgent?.id).toBe(first);
  });
  test("opening a conversation from a different agent restores its actual owner", async () => {
    const library = await load();
    const original = library.ownerId;
    const firstTopic = library.topicId;
    await library.createAgent("第二位");
    await library.selectTopic(firstTopic);
    expect(library.ownerType).toBe("agent");
    expect(library.ownerId).toBe(original);
    expect(library.currentAgent?.id).toBe(original);
    await library.selectTopic("missing");
    expect(library.topicId).toBe(firstTopic);
  });
  test("each agent remembers its selected conversation while the user switches agents", async () => {
    const library = await load();
    const first = library.ownerId;
    const original = library.topicId;
    await library.createTopic();
    const secondTopic = library.topicId;
    await library.selectTopic(original);
    await library.createAgent("另一位");
    await library.selectOwner("agent", first);
    expect(library.topicId).toBe(original);
    expect(library.ownerTopics.some((t) => t.id === secondTopic)).toBe(true);
  });
  test("new conversation creates one topic for the chosen owner, without moving old topics", async () => {
    const library = await load();
    const first = library.ownerId;
    const original = library.topicId;
    await library.createAgent("第二位");
    const before = library.topics.length;
    await library.createTopicFor("agent", first);
    expect(library.ownerId).toBe(first);
    expect(library.topics).toHaveLength(before + 1);
    expect(library.topicId).not.toBe(original);
  });
  test("deleting an inactive conversation does not navigate away from the current one", async () => {
    const library = await load();
    const inactive = library.topicId;
    await library.createTopic();
    const active = library.topicId;
    await library.removeTopic(inactive);
    expect(library.topicId).toBe(active);
  });
  test("deleting the main agent falls back to a remaining agent", async () => {
    const library = await load();
    const first = library.ownerId;
    await library.createAgent("主 Agent");
    const removed = library.ownerId;
    await library.setMainAgent(removed);
    await library.removeAgent(removed);
    expect(library.mainAgent?.id).toBe(first);
    expect(library.currentAgent?.id).toBe(first);
    expect(useSettingsStore().settings.mainAgentId).toBe("");
  });
  test("conversation drafts and attachments are independent", () => {
    const workspace = useWorkspaceStore();
    workspace.saveDraft("one", {
      text: "第一份草稿",
      attachments: [
        {
          id: "file",
          name: "a.txt",
          mime: "text/plain",
          kind: "text",
          text: "内容",
        },
      ],
    });
    workspace.saveDraft("two", { text: "第二份草稿" });
    expect(workspace.draftFor("one").attachments).toHaveLength(1);
    expect(workspace.draftFor("two").attachments).toEqual([]);
    workspace.clearDraft("two");
    expect(workspace.draftFor("one").text).toBe("第一份草稿");
    expect(workspace.draftFor("two").text).toBe("");
  });
  test("sheets remain mounted through exit motion and reopening cancels stale closure", () => {
    vi.useFakeTimers();
    const workspace = useWorkspaceStore();
    workspace.open({ type: "agent" }); workspace.close();
    expect(workspace.closing).toBe(true); expect(workspace.sheet?.type).toBe("agent");
    vi.advanceTimersByTime(100); workspace.open({ type: "main-agent" });
    vi.advanceTimersByTime(100); expect(workspace.sheet?.type).toBe("main-agent");
    workspace.openActivity("rag"); workspace.closeActivity();
    expect(workspace.activityOpen).toBe(true);
    vi.advanceTimersByTime(180); expect(workspace.activityOpen).toBe(false);
    workspace.close(); vi.advanceTimersByTime(180); expect(workspace.sheet).toBeNull();
    vi.useRealTimers();
  });

});
