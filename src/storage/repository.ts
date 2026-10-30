import type { Agent, ChatMessage, Group, LocalNote, LogEntry, Settings, Topic } from "../domain";

export interface Repository {
  getSettings(): Promise<Settings>;
  saveSettings(settings: Settings): Promise<void>;
  listAgents(): Promise<Agent[]>;
  saveAgent(agent: Agent): Promise<void>;
  deleteAgent(id: string): Promise<void>;
  listGroups(): Promise<Group[]>;
  saveGroup(group: Group): Promise<void>;
  deleteGroup(id: string): Promise<void>;
  listTopics(): Promise<Topic[]>;
  saveTopic(topic: Topic): Promise<void>;
  deleteTopic(id: string): Promise<void>;
  listMessages(topicId: string): Promise<ChatMessage[]>;
  saveMessage(message: ChatMessage): Promise<void>;
  /** Replies still marked as streaming, across all topics. */
  listUnfinishedMessages(): Promise<ChatMessage[]>;
  listNotes(): Promise<LocalNote[]>;
  saveNote(note: LocalNote): Promise<void>;
  deleteNote(id: string): Promise<void>;
  listLogs(): Promise<LogEntry[]>;
  saveLogs(entries: LogEntry[]): Promise<void>;
}
