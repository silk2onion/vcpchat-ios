import { defaultSettings, LIMITS, type Agent, type ChatMessage, type Group, type LocalNote, type LogEntry, type Settings, type Topic } from "../domain";
import type { Repository } from "./repository";

const DB_NAME = "vcpchat-ios";
const DB_VERSION = 1;

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("meta")) db.createObjectStore("meta");
      for (const name of ["agents", "groups", "topics", "messages", "notes"]) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("无法打开本地数据库"));
  });
}

function toPlain<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function requestToPromise<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("本地数据库读写失败"));
  });
}

async function transaction<T>(storeNames: string[], mode: IDBTransactionMode, run: (stores: IDBObjectStore[]) => Promise<T> | T): Promise<T> {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeNames, mode);
    const stores = storeNames.map((name) => tx.objectStore(name));
    Promise.resolve(run(stores)).then(resolve, reject);
    tx.onerror = () => reject(tx.error ?? new Error("本地数据库事务失败"));
  });
}

export function createIndexedDbRepository(): Repository {
  const memoryFallback = typeof indexedDB === "undefined";
  if (memoryFallback) {
    throw new Error("当前环境没有 IndexedDB");
  }

  return {
    async getSettings() {
      const stored = await transaction(["meta"], "readonly", (stores) => requestToPromise(stores[0].get("settings") as IDBRequest<Settings | undefined>));
      return { ...defaultSettings(), ...(stored ?? {}) };
    },
    async saveSettings(settings) {
      await transaction(["meta"], "readwrite", (stores) => requestToPromise(stores[0].put(toPlain(settings), "settings")));
    },
    async listAgents() {
      const rows = await all<Agent>("agents");
      return rows.sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveAgent(agent) {
      await put("agents", agent);
    },
    async deleteAgent(id) {
      const topics = (await this.listTopics()).filter((topic) => topic.ownerType === "agent" && topic.ownerId === id);
      for (const topic of topics) await this.deleteTopic(topic.id);
      const groups = await this.listGroups();
      for (const group of groups) {
        if (group.memberIds.includes(id)) await this.saveGroup({ ...group, memberIds: group.memberIds.filter((memberId) => memberId !== id) });
      }
      await remove("agents", id);
    },
    async listGroups() {
      const rows = await all<Group>("groups");
      return rows.sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveGroup(group) {
      await put("groups", group);
    },
    async deleteGroup(id) {
      const topics = (await this.listTopics()).filter((topic) => topic.ownerType === "group" && topic.ownerId === id);
      for (const topic of topics) await this.deleteTopic(topic.id);
      await remove("groups", id);
    },
    async listTopics() {
      const rows = await all<Topic>("topics");
      return rows.sort((a, b) => b.updatedAt - a.updatedAt);
    },
    async saveTopic(topic) {
      await put("topics", topic);
    },
    async deleteTopic(id) {
      const messages = (await all<ChatMessage>("messages")).filter((message) => message.topicId === id);
      await transaction(["topics", "messages"], "readwrite", async (stores) => {
        await requestToPromise(stores[0].delete(id));
        await Promise.all(messages.map((message) => requestToPromise(stores[1].delete(message.id))));
      });
    },
    async listMessages(topicId) {
      const rows = await all<ChatMessage>("messages");
      return rows.filter((message) => message.topicId === topicId).sort((a, b) => a.createdAt - b.createdAt);
    },
    async saveMessage(message) {
      await put("messages", message);
    },
    async listNotes() {
      const rows = await all<LocalNote>("notes");
      return rows.sort((a, b) => b.updatedAt - a.updatedAt);
    },
    async saveNote(note) {
      await put("notes", note);
    },
    async deleteNote(id) {
      await remove("notes", id);
    },
    async listLogs() {
      const stored = await transaction(["meta"], "readonly", (stores) => requestToPromise(stores[0].get("logs") as IDBRequest<LogEntry[] | undefined>));
      return stored ?? [];
    },
    async saveLogs(entries) {
      await transaction(["meta"], "readwrite", (stores) =>
        requestToPromise(stores[0].put(toPlain(entries.slice(-LIMITS.maxLogEntries)), "logs")),
      );
    },
  };
}

function all<T>(storeName: string): Promise<T[]> {
  return transaction([storeName], "readonly", (stores) => requestToPromise(stores[0].getAll() as IDBRequest<T[]>));
}

function put(storeName: string, value: unknown): Promise<IDBValidKey> {
  const plain = toPlain(value);
  return transaction([storeName], "readwrite", (stores) => requestToPromise(stores[0].put(plain)));
}

function remove(storeName: string, id: string): Promise<undefined> {
  return transaction([storeName], "readwrite", (stores) => requestToPromise(stores[0].delete(id)));
}
