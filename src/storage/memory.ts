import { emptyVault, type SyncVault, type LocalFile, type SyncCommit } from "../sync/types";
import { validateSyncCommit } from "./sync";
import { defaultSettings, type Agent, type ChatMessage, type Group, type LocalNote, type LogEntry, type Topic } from "../domain";
import type { Repository } from "./repository";

export function createMemoryRepository(): Repository {
  const settings = defaultSettings();
  const agents = new Map<string, Agent>();
  const groups = new Map<string, Group>();
  const topics = new Map<string, Topic>();
  const messages = new Map<string, ChatMessage>();
  const notes = new Map<string, LocalNote>();
  const versions: Record<string,number> = {};
  let vault: SyncVault = emptyVault();
  const files = new Map<string, LocalFile>();
  let logs: LogEntry[] = [];

  return {
    async readSnapshot() { return structuredClone({ agents: [...agents.values()], groups: [...groups.values()], topics: [...topics.values()], messages: [...messages.values()] }); },
    async getSyncVault() { return {...structuredClone(vault),localVersions:{...versions}}; },
    async commitSync(commit: SyncCommit) {
      validateSyncCommit(commit, { agents: [...agents.values()], groups: [...groups.values()], topics: [...topics.values()], messages: [...messages.values()] });
      for (const [name, map] of [["agents", agents], ["groups", groups], ["topics", topics], ["messages", messages]] as const) {
        for (const old of commit.before[name]) map.delete(old.id);
        for (const row of commit.after[name]) (map as Map<string, unknown>).set(row.id, structuredClone(row));
      }
      vault = structuredClone(commit.vault);
    },
    async listFiles() { return [...files.values()].map(({bytes: _bytes, ...meta}) => meta); },
    async getFile(id: string) { const file = files.get(id); return file && structuredClone(file); },
    async saveFile(file: LocalFile) { files.set(file.id, structuredClone(file)); },
    async deleteFile(id: string) { files.delete(id); },
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
      versions["agents\0"+agent.id]=Date.now();
      agents.set(agent.id, { ...agent });
    },
    async deleteAgent(id) {
      versions["agents\0"+id]=Date.now();
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
      versions["groups\0"+group.id]=Date.now();
      groups.set(group.id, { ...group, memberIds: [...group.memberIds] });
    },
    async deleteGroup(id) {
      versions["groups\0"+id]=Date.now();
      const owned = [...topics.values()].filter((topic) => topic.ownerType === "group" && topic.ownerId === id);
      for (const topic of owned) await this.deleteTopic(topic.id);
      groups.delete(id);
    },
    async listTopics() {
      return [...topics.values()].sort((a, b) => b.updatedAt - a.updatedAt);
    },
    async saveTopic(topic) {
      versions["topics\0"+topic.id]=Date.now();
      topics.set(topic.id, { ...topic });
    },
    async deleteTopic(id) {
      versions["topics\0"+id]=Date.now();
      topics.delete(id);
      for (const message of messages.values()) {
        if (message.topicId === id) messages.delete(message.id);
      }
    },
    async listMessages(topicId) {
      return [...messages.values()].filter((message) => message.topicId === topicId).sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveMessage(message) {
      versions["messages\0"+message.id]=Date.now();
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
