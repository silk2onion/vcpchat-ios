import { defineStore } from "pinia";
import { computed, ref } from "vue";
import type { Agent, Attachment, ChatMessage, Group, GroupMode, Topic } from "../domain";
import { createId } from "../protocol/ids";
import { resolveChatEndpoint } from "../protocol/endpoint";
import { selectSpeakers } from "../protocol/groups";
import { buildRequestBody, resolveModel, toApiMessages } from "../protocol/messages";
import { getChatTransport } from "../protocol/transport";
import { ensureSeed, getRepository } from "../storage";
import { useSettingsStore } from "./settings";

export const useLibraryStore = defineStore("library", () => {
  const agents = ref<Agent[]>([]);
  const groups = ref<Group[]>([]);
  const topics = ref<Topic[]>([]);
  const messages = ref<ChatMessage[]>([]);
  const ownerType = ref<"agent" | "group">("agent");
  const ownerId = ref("");
  const topicId = ref("");
  const streaming = ref(false);
  const error = ref("");
  let abort: AbortController | null = null;

  const currentAgent = computed(() => agents.value.find((agent) => agent.id === ownerId.value) ?? null);
  const currentGroup = computed(() => groups.value.find((group) => group.id === ownerId.value) ?? null);
  const ownerTopics = computed(() => topics.value.filter((topic) => topic.ownerType === ownerType.value && topic.ownerId === ownerId.value));
  const currentTopic = computed(() => topics.value.find((topic) => topic.id === topicId.value) ?? null);
  const configured = computed(() => {
    const settings = useSettingsStore().settings;
    return Boolean(settings.serverUrl.trim() && settings.apiKey.trim() && (settings.defaultModel.trim() || agents.value.some((agent) => agent.model.trim())));
  });

  async function load() {
    await ensureSeed(getRepository());
    agents.value = await getRepository().listAgents();
    groups.value = await getRepository().listGroups();
    topics.value = await getRepository().listTopics();
    if (!ownerId.value && agents.value[0]) await selectOwner("agent", agents.value[0].id);
    else if (topicId.value) messages.value = await getRepository().listMessages(topicId.value);
  }

  async function selectOwner(type: "agent" | "group", id: string) {
    ownerType.value = type;
    ownerId.value = id;
    const existing = topics.value.find((topic) => topic.ownerType === type && topic.ownerId === id);
    if (existing) await selectTopic(existing.id);
    else await createTopic();
  }

  async function selectTopic(id: string) {
    topicId.value = id;
    messages.value = await getRepository().listMessages(id);
    error.value = "";
  }

  async function createAgent(name: string) {
    const agent: Agent = {
      id: createId("agent"),
      name: name.trim() || "未命名助手",
      systemPrompt: "",
      model: "",
      temperature: null,
      createdAt: Date.now(),
    };
    await getRepository().saveAgent(agent);
    agents.value = [...agents.value, agent];
    await selectOwner("agent", agent.id);
  }

  async function saveAgent(agent: Agent) {
    await getRepository().saveAgent(agent);
    agents.value = agents.value.map((item) => (item.id === agent.id ? agent : item));
  }

  async function removeAgent(id: string) {
    await getRepository().deleteAgent(id);
    await load();
    ownerId.value = "";
    if (agents.value[0]) await selectOwner("agent", agents.value[0].id);
  }

  async function createGroup(name: string, memberIds: string[], mode: GroupMode) {
    const group: Group = {
      id: createId("group"),
      name: name.trim() || "未命名群组",
      memberIds,
      mode,
      createdAt: Date.now(),
    };
    await getRepository().saveGroup(group);
    groups.value = [...groups.value, group];
    await selectOwner("group", group.id);
  }

  async function saveGroup(group: Group) {
    await getRepository().saveGroup(group);
    groups.value = groups.value.map((item) => (item.id === group.id ? group : item));
  }

  async function removeGroup(id: string) {
    await getRepository().deleteGroup(id);
    await load();
    ownerId.value = "";
    if (agents.value[0]) await selectOwner("agent", agents.value[0].id);
  }

  async function createTopic() {
    if (!ownerId.value) return;
    const now = Date.now();
    const topic: Topic = {
      id: createId("topic"),
      ownerType: ownerType.value,
      ownerId: ownerId.value,
      title: "新的对话",
      turnIndex: 0,
      createdAt: now,
      updatedAt: now,
    };
    await getRepository().saveTopic(topic);
    topics.value = [topic, ...topics.value.filter((item) => item.id !== topic.id)];
    await selectTopic(topic.id);
  }

  async function renameTopic(title: string) {
    const topic = currentTopic.value;
    if (!topic) return;
    const next = { ...topic, title: title.trim() || "新的对话", updatedAt: Date.now() };
    await getRepository().saveTopic(next);
    topics.value = topics.value.map((item) => (item.id === next.id ? next : item));
  }

  async function removeTopic(id: string) {
    await getRepository().deleteTopic(id);
    topics.value = topics.value.filter((topic) => topic.id !== id);
    const fallback = ownerTopics.value[0];
    if (fallback) await selectTopic(fallback.id);
    else await createTopic();
  }

  function stop() {
    abort?.abort();
  }

  async function send(text: string, attachments: Attachment[]) {
    const topic = currentTopic.value;
    const trimmed = text.trim();
    if (!topic || streaming.value) return;
    if (!trimmed && attachments.length === 0) return;
    const settingsStore = useSettingsStore();
    const settings = settingsStore.settings;
    if (!settings.serverUrl.trim() || !settings.apiKey.trim()) {
      error.value = "先在设置里填写服务器地址和 API Key。";
      return;
    }
    error.value = "";
    try {
      await deliver(topic, trimmed, attachments);
    } catch (caught) {
      error.value = caught instanceof Error ? caught.message : "发送失败";
    }
  }

  async function deliver(topic: Topic, trimmed: string, attachments: Attachment[]) {
    const settingsStore = useSettingsStore();
    const settings = settingsStore.settings;
    const userMessage: ChatMessage = {
      id: createId("msg"),
      topicId: topic.id,
      role: "user",
      content: trimmed,
      reasoning: "",
      authorName: settings.userName.trim() || "我",
      attachments,
      createdAt: Date.now(),
      status: "complete",
    };
    await persistMessage(userMessage);
    if (topic.title === "新的对话" && trimmed) await renameTopic(trimmed.slice(0, 24));
    const speakers = speakersFor(topic, trimmed);
    if (!speakers.length) {
      error.value = ownerType.value === "group" ? "这个群组还没有可发言的成员。" : "没有可用的助手。";
      return;
    }
    streaming.value = true;
    abort = new AbortController();
    try {
      for (const speaker of speakers) {
        if (abort.signal.aborted) break;
        if (!resolveModel(speaker, settings)) {
          error.value = `「${speaker.name}」还没有模型。请在设置里选择默认模型。`;
          break;
        }
        const placeholder: ChatMessage = {
          id: createId("msg"),
          topicId: topic.id,
          role: "assistant",
          content: "",
          reasoning: "",
          agentId: speaker.id,
          authorName: speaker.name,
          attachments: [],
          createdAt: Date.now(),
          status: "streaming",
        };
        messages.value = [...messages.value, placeholder];
        try {
          const apiMessages = toApiMessages({
            settings,
            agent: speaker,
            group: ownerType.value === "group" ? currentGroup.value : null,
            messages: messages.value,
          });
          const body = buildRequestBody(settings, speaker, apiMessages);
          const url = resolveChatEndpoint(settings.serverUrl, settings.endpointMode);
          await getChatTransport().stream({
            url,
            apiKey: settings.apiKey,
            body,
            signal: abort.signal,
            handlers: {
              onContent: (chunk) => replaceMessage(placeholder.id, (current) => ({ ...current, content: current.content + chunk })),
              onReasoning: (chunk) => replaceMessage(placeholder.id, (current) => ({ ...current, reasoning: current.reasoning + chunk })),
            },
          });
          replaceMessage(placeholder.id, (current) => ({ ...current, status: "complete" }));
        } catch (caught) {
          const aborted = abort.signal.aborted || (caught instanceof DOMException && caught.name === "AbortError");
          const message = caught instanceof Error ? caught.message : "请求失败";
          replaceMessage(placeholder.id, (current) => ({
            ...current,
            status: aborted ? "stopped" : "error",
            error: aborted ? "已停止" : message,
          }));
          if (!aborted) error.value = message;
          break;
        }
        await persistCurrent(placeholder.id);
      }
      if (ownerType.value === "group") {
        const updated = topics.value.find((item) => item.id === topic.id);
        if (updated) {
          const next = { ...updated, turnIndex: updated.turnIndex + 1, updatedAt: Date.now() };
          await getRepository().saveTopic(next);
          topics.value = topics.value.map((item) => (item.id === next.id ? next : item));
        }
      }
    } finally {
      streaming.value = false;
      abort = null;
    }
  }

  function speakersFor(topic: Topic, text: string): Agent[] {
    if (topic.ownerType === "agent") {
      const agent = agents.value.find((item) => item.id === topic.ownerId);
      return agent ? [agent] : [];
    }
    const group = groups.value.find((item) => item.id === topic.ownerId);
    if (!group) return [];
    return selectSpeakers(group, agents.value, text, topic.turnIndex);
  }

  function replaceMessage(id: string, update: (message: ChatMessage) => ChatMessage) {
    messages.value = messages.value.map((message) => (message.id === id ? update(message) : message));
  }

  async function persistMessage(message: ChatMessage) {
    messages.value = [...messages.value, message];
    await getRepository().saveMessage(message);
    await touchTopic(message.topicId);
  }

  async function persistCurrent(id: string) {
    const message = messages.value.find((item) => item.id === id);
    if (message) await getRepository().saveMessage(message);
  }

  async function touchTopic(id: string) {
    const topic = topics.value.find((item) => item.id === id);
    if (!topic) return;
    const next = { ...topic, updatedAt: Date.now() };
    topics.value = topics.value.map((item) => (item.id === id ? next : item));
    await getRepository().saveTopic(next);
  }

  async function clearHistory() {
    const repository = getRepository();
    for (const topic of await repository.listTopics()) await repository.deleteTopic(topic.id);
    topics.value = [];
    messages.value = [];
    await createTopic();
  }

  return {
    agents,
    groups,
    topics,
    messages,
    ownerType,
    ownerId,
    topicId,
    streaming,
    error,
    currentAgent,
    currentGroup,
    ownerTopics,
    currentTopic,
    configured,
    load,
    selectOwner,
    selectTopic,
    createAgent,
    saveAgent,
    removeAgent,
    createGroup,
    saveGroup,
    removeGroup,
    createTopic,
    renameTopic,
    removeTopic,
    send,
    stop,
    clearHistory,
  };
});
