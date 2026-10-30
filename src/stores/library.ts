import { defineStore } from "pinia";
import { computed, ref } from "vue";
import type { Agent, Attachment, ChatMessage, Group, GroupMode, Topic } from "../domain";
import { createId } from "../protocol/ids";
import { resolveChatEndpoint } from "../protocol/endpoint";
import { selectSpeakers } from "../protocol/groups";
import { buildRequestBody, resolveModel, toApiMessages, type ApiMessage } from "../protocol/messages";
import { getChatTransport, StreamLostError, type ChatTransport } from "../protocol/transport";
import { ensureSeed, getRepository } from "../storage";
import { useSettingsStore } from "./settings";

export const CONTINUE_PROMPT = "上一条回复在传输中断开了。请从断开的地方直接接着写，不要重复已经写过的内容，也不要解释。";
const PERSIST_EVERY_MS = 1000;

interface LiveReply {
  topicId: string;
  message: ChatMessage;
  dirty: boolean;
}

type Outcome = "complete" | "stopped" | "interrupted" | "error";

export const useLibraryStore = defineStore("library", () => {
  const agents = ref<Agent[]>([]);
  const groups = ref<Group[]>([]);
  const topics = ref<Topic[]>([]);
  const messages = ref<ChatMessage[]>([]);
  const ownerType = ref<"agent" | "group">("agent");
  const ownerId = ref("");
  const topicId = ref("");
  const runningTopics = ref<string[]>([]);
  const error = ref("");
  /** Replies being written, keyed by message id. They live here, not in `messages`, so switching topics does not drop them. */
  const live = new Map<string, LiveReply>();
  const runs = new Map<string, AbortController>();
  let persistTimer: ReturnType<typeof setTimeout> | null = null;

  const streaming = computed(() => runningTopics.value.includes(topicId.value));
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
    forgetMissingTopics();
    if (!ownerId.value && agents.value[0]) await selectOwner("agent", agents.value[0].id);
    else if (topicId.value) await showTopic(topicId.value);
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
    await showTopic(id);
    error.value = "";
  }

  async function showTopic(id: string) {
    const stored = await getRepository().listMessages(id);
    if (topicId.value !== id) return;
    const overlaid = stored.map((message) => live.get(message.id)?.message ?? message);
    for (const reply of live.values()) {
      if (reply.topicId === id && !overlaid.some((message) => message.id === reply.message.id)) overlaid.push(reply.message);
    }
    messages.value = overlaid;
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

  async function renameTopic(title: string, id = topicId.value) {
    const topic = topics.value.find((item) => item.id === id);
    if (!topic) return;
    const next = { ...topic, title: title.trim() || "新的对话", updatedAt: Date.now() };
    await getRepository().saveTopic(next);
    topics.value = topics.value.map((item) => (item.id === next.id ? next : item));
  }

  async function removeTopic(id: string) {
    forgetTopic(id);
    await getRepository().deleteTopic(id);
    topics.value = topics.value.filter((topic) => topic.id !== id);
    const fallback = ownerTopics.value[0];
    if (fallback) await selectTopic(fallback.id);
    else await createTopic();
  }

  function stop() {
    runs.get(topicId.value)?.abort();
  }

  async function send(text: string, attachments: Attachment[]) {
    const topic = currentTopic.value;
    const trimmed = text.trim();
    if (!topic || runs.has(topic.id)) return;
    if (!trimmed && attachments.length === 0) return;
    const settings = useSettingsStore().settings;
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
    const settings = useSettingsStore().settings;
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
    if (topic.title === "新的对话" && trimmed) await renameTopic(trimmed.slice(0, 24), topic.id);
    const speakers = speakersFor(topic, trimmed);
    if (!speakers.length) {
      error.value = topic.ownerType === "group" ? "这个群组还没有可发言的成员。" : "没有可用的助手。";
      return;
    }
    const group = topic.ownerType === "group" ? (groups.value.find((item) => item.id === topic.ownerId) ?? null) : null;
    const transcript = await getRepository().listMessages(topic.id);
    const controller = beginRun(topic.id);
    try {
      for (const speaker of speakers) {
        if (controller.signal.aborted) break;
        if (!resolveModel(speaker, settings)) {
          showError(topic.id, `「${speaker.name}」还没有模型。请在设置里选择默认模型。`);
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
        const apiMessages = toApiMessages({ settings, agent: speaker, group, messages: transcript });
        track(placeholder);
        const { outcome, message } = await streamReply(placeholder.id, buildRequestBody(settings, speaker, apiMessages), controller.signal);
        if (message) transcript.push(message);
        if (outcome !== "complete") break;
      }
      if (group) {
        const updated = topics.value.find((item) => item.id === topic.id);
        if (updated) {
          const next = { ...updated, turnIndex: updated.turnIndex + 1, updatedAt: Date.now() };
          await getRepository().saveTopic(next);
          topics.value = topics.value.map((item) => (item.id === next.id ? next : item));
        }
      }
    } finally {
      endRun(topic.id, controller);
    }
  }

  /** Asks the same speaker to pick up an interrupted reply and appends to it. */
  async function continueMessage(id: string) {
    const topic = currentTopic.value;
    const index = messages.value.findIndex((message) => message.id === id);
    const target = messages.value[index];
    if (!topic || !target || target.role !== "assistant" || runs.has(topic.id)) return;
    if (index !== messages.value.length - 1) return;
    const settings = useSettingsStore().settings;
    const speaker = agents.value.find((agent) => agent.id === target.agentId) ?? (topic.ownerType === "agent" ? currentAgent.value : null);
    if (!speaker) {
      error.value = "找不到写这条回复的助手，没法续写。";
      return;
    }
    if (!resolveModel(speaker, settings)) {
      error.value = `「${speaker.name}」还没有模型。请在设置里选择默认模型。`;
      return;
    }
    const group = topic.ownerType === "group" ? (groups.value.find((item) => item.id === topic.ownerId) ?? null) : null;
    const apiMessages: ApiMessage[] = [
      ...toApiMessages({ settings, agent: speaker, group, messages: messages.value.slice(0, index + 1) }),
      { role: "user", content: CONTINUE_PROMPT },
    ];
    error.value = "";
    const controller = beginRun(topic.id);
    try {
      track({
        ...target,
        status: "streaming",
        error: undefined,
        streamId: undefined,
        streamOffset: { content: target.content.length, reasoning: target.reasoning.length },
      });
      await streamReply(id, buildRequestBody(settings, speaker, apiMessages), controller.signal);
    } finally {
      endRun(topic.id, controller);
    }
  }

  async function streamReply(id: string, body: string, signal: AbortSignal): Promise<{ outcome: Outcome; message?: ChatMessage }> {
    const settings = useSettingsStore().settings;
    const transport = getChatTransport();
    try {
      await transport.stream({
        url: resolveChatEndpoint(settings.serverUrl, settings.endpointMode),
        apiKey: settings.apiKey,
        body,
        signal,
        handlers: replyHandlers(id, true),
      });
      return await finish(id, transport, "complete");
    } catch (caught) {
      const aborted = signal.aborted || (caught instanceof DOMException && caught.name === "AbortError");
      return await finish(id, transport, aborted ? "stopped" : failureOf(id), caught);
    }
  }

  function replyHandlers(id: string, persistStreamId: boolean) {
    return {
      onStreamId: (streamId: string) => {
        patchLive(id, (current) => ({ ...current, streamId }));
        if (persistStreamId) void flushStreams();
      },
      onContent: (chunk: string) => patchLive(id, (current) => ({ ...current, content: current.content + chunk })),
      onReasoning: (chunk: string) => patchLive(id, (current) => ({ ...current, reasoning: current.reasoning + chunk })),
    };
  }

  function failureOf(id: string): Outcome {
    const current = live.get(id)?.message;
    return current && (current.content.trim() || current.reasoning.trim()) ? "interrupted" : "error";
  }

  async function finish(id: string, transport: ChatTransport, outcome: Outcome, caught?: unknown): Promise<{ outcome: Outcome; message?: ChatMessage }> {
    const reply = live.get(id);
    const current = reply?.message;
    if (!current) return { outcome: "stopped" };
    const reason = caught instanceof Error ? caught.message : "请求失败";
    const errorText = outcome === "stopped" ? "已停止" : outcome === "interrupted" ? `连接断开，已保存写到的部分：${reason}` : outcome === "error" ? reason : undefined;
    const message: ChatMessage = { ...current, status: outcome, error: errorText, streamId: undefined, streamOffset: undefined };
    live.delete(id);
    showMessage(message);
    await getRepository().saveMessage(message);
    if (outcome === "error") showError(message.topicId, reason);
    if (current.streamId) void transport.release?.(current.streamId);
    return { outcome, message };
  }

  /** Re-attaches to replies that were still streaming when the page went away. */
  async function recoverStreams() {
    const transport = getChatTransport();
    const unfinished = await getRepository().listUnfinishedMessages();
    await Promise.all(
      unfinished
        .filter((message) => !live.has(message.id) && topics.value.some((topic) => topic.id === message.topicId))
        .map((message) => (message.streamId && transport.resume ? reattach(message, transport) : markInterrupted(message))),
    );
  }

  async function reattach(saved: ChatMessage, transport: ChatTransport) {
    const settings = useSettingsStore().settings;
    const offset = saved.streamOffset ?? { content: 0, reasoning: 0 };
    const controller = beginRun(saved.topicId);
    track({ ...saved, content: saved.content.slice(0, offset.content), reasoning: saved.reasoning.slice(0, offset.reasoning) });
    try {
      await transport.resume?.({ streamId: saved.streamId ?? "", apiKey: settings.apiKey, signal: controller.signal, handlers: replyHandlers(saved.id, false) });
      await finish(saved.id, transport, "complete");
    } catch (caught) {
      const replayed = live.get(saved.id)?.message;
      if (replayed && replayed.content.length < saved.content.length) {
        patchLive(saved.id, (current) => ({ ...current, content: saved.content, reasoning: saved.reasoning }));
      }
      const aborted = controller.signal.aborted;
      const lost = caught instanceof StreamLostError ? new Error("应用重新打开前连接就已断开") : caught;
      await finish(saved.id, transport, aborted ? "stopped" : failureOf(saved.id), lost);
    } finally {
      endRun(saved.topicId, controller);
    }
  }

  async function markInterrupted(saved: ChatMessage) {
    const produced = saved.content.trim() || saved.reasoning.trim();
    const message: ChatMessage = {
      ...saved,
      status: produced ? "interrupted" : "error",
      error: produced ? "应用关闭时这条回复还没写完，已保存写到的部分" : "应用关闭时这条回复还没开始",
      streamId: undefined,
      streamOffset: undefined,
    };
    await getRepository().saveMessage(message);
    showMessage(message);
  }

  /** Writes every reply in progress to storage now, e.g. before iOS suspends the app. */
  async function flushStreams() {
    if (persistTimer) {
      clearTimeout(persistTimer);
      persistTimer = null;
    }
    const dirty = [...live.values()].filter((reply) => reply.dirty);
    for (const reply of dirty) reply.dirty = false;
    await Promise.all(dirty.map((reply) => getRepository().saveMessage(reply.message)));
  }

  function schedulePersist() {
    persistTimer ??= setTimeout(() => {
      persistTimer = null;
      void flushStreams();
    }, PERSIST_EVERY_MS);
  }

  function track(message: ChatMessage) {
    live.set(message.id, { topicId: message.topicId, message, dirty: true });
    showMessage(message);
    schedulePersist();
  }

  function patchLive(id: string, update: (message: ChatMessage) => ChatMessage) {
    const reply = live.get(id);
    if (!reply) return;
    reply.message = update(reply.message);
    reply.dirty = true;
    showMessage(reply.message);
    schedulePersist();
  }

  function showMessage(message: ChatMessage) {
    if (message.topicId !== topicId.value) return;
    const index = messages.value.findIndex((item) => item.id === message.id);
    if (index < 0) messages.value = [...messages.value, message];
    else messages.value = messages.value.map((item, position) => (position === index ? message : item));
  }

  function showError(topic: string, message: string) {
    if (topic === topicId.value) error.value = message;
  }

  function beginRun(topic: string): AbortController {
    const controller = new AbortController();
    runs.set(topic, controller);
    if (!runningTopics.value.includes(topic)) runningTopics.value = [...runningTopics.value, topic];
    return controller;
  }

  function endRun(topic: string, controller: AbortController) {
    if (runs.get(topic) !== controller) return;
    runs.delete(topic);
    runningTopics.value = runningTopics.value.filter((item) => item !== topic);
  }

  function forgetTopic(topic: string) {
    runs.get(topic)?.abort();
    for (const [id, reply] of live) if (reply.topicId === topic) live.delete(id);
  }

  function forgetMissingTopics() {
    const known = new Set(topics.value.map((topic) => topic.id));
    for (const reply of [...live.values()]) if (!known.has(reply.topicId)) forgetTopic(reply.topicId);
    for (const topic of [...runs.keys()]) if (!known.has(topic)) forgetTopic(topic);
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

  async function persistMessage(message: ChatMessage) {
    showMessage(message);
    await getRepository().saveMessage(message);
    await touchTopic(message.topicId);
  }

  async function touchTopic(id: string) {
    const topic = topics.value.find((item) => item.id === id);
    if (!topic) return;
    const next = { ...topic, updatedAt: Date.now() };
    topics.value = topics.value.map((item) => (item.id === id ? next : item));
    await getRepository().saveTopic(next);
  }

  async function clearHistory() {
    for (const topic of [...runs.keys()]) forgetTopic(topic);
    live.clear();
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
    runningTopics,
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
    continueMessage,
    recoverStreams,
    flushStreams,
    clearHistory,
  };
});
