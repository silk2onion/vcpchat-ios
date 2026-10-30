import { defaultSettings, type Agent, type ChatMessage, type Group, type LocalNote, type LogEntry, type Topic } from "../domain";
import type { Repository } from "./repository";

export function createMemoryRepository(): Repository {
  const settings = defaultSettings();
  const agents = new Map<string, Agent>();
  const groups = new Map<string, Group>();
  const topics = new Map<string, Topic>();
  const messages = new Map<string, ChatMessage>();
  const notes = new Map<string, LocalNote>();
  let logs: LogEntry[] = [];

  return {
    async getSettings() {
      return { ...settings };
    },
    async saveSettings(next) {
      Object.assign(settings, next);
    },
    async listAgents() {
      return [...agents.values()].sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveAgent(agent) {
      agents.set(agent.id, { ...agent });
    },
    async deleteAgent(id) {
      const owned = [...topics.values()].filter((topic) => topic.ownerType === "agent" && topic.ownerId === id);
      for (const topic of owned) await this.deleteTopic(topic.id);
      for (const group of groups.values()) {
        if (group.memberIds.includes(id)) {
          groups.set(group.id, { ...group, memberIds: group.memberIds.filter((memberId) => memberId !== id) });
        }
      }
      agents.delete(id);
    },
    async listGroups() {
      return [...groups.values()].sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveGroup(group) {
      groups.set(group.id, { ...group, memberIds: [...group.memberIds] });
    },
    async deleteGroup(id) {
      const owned = [...topics.values()].filter((topic) => topic.ownerType === "group" && topic.ownerId === id);
      for (const topic of owned) await this.deleteTopic(topic.id);
      groups.delete(id);
    },
    async listTopics() {
      return [...topics.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    },
    async saveTopic(topic) {
      topics.set(topic.id, { ...topic });
    },
    async deleteTopic(id) {
      topics.delete(id);
      for (const message of messages.values()) {
        if (message.topicId === id) messages.delete(message.id);
      }
    },
    async listMessages(topicId) {
      return [...messages.values()].filter((message) => message.topicId === topicId).sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveMessage(message) {
      messages.set(message.id, { ...message, attachments: message.attachments.map((file) => ({ ...file })) });
    },
    async listUnfinishedMessages() {
      return [...messages.values()].filter((message) => message.status === "streaming").map((message) => ({ ...message }));
    },
    async listNotes() {
      return [...notes.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    },
    async saveNote(note) {
      notes.set(note.id, { ...note });
    },
    async deleteNote(id) {
      notes.delete(id);
    },
    async listLogs() {
      return logs.map((entry) => ({ ...entry }));
    },
    async saveLogs(entries) {
      logs = entries.map((entry) => ({ ...entry }));
    },
  };
}
