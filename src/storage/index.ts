import { createIndexedDbRepository } from "./indexeddb";
import { createMemoryRepository } from "./memory";
import type { Repository } from "./repository";

let current: Repository | null = null;

export function installRepository(repository?: Repository) {
  current = repository ?? createDefaultRepository();
}

export function getRepository(): Repository {
  if (!current) current = createDefaultRepository();
  return current;
}

export function createDefaultRepository(): Repository {
  if (typeof indexedDB === "undefined") return createMemoryRepository();
  return createIndexedDbRepository();
}

export async function ensureSeed(repository: Repository): Promise<void> {
  const agents = await repository.listAgents();
  if (agents.length) return;
  const now = Date.now();
  const agent = {
    id: "agent_default",
    name: "助手",
    systemPrompt: "",
    model: "",
    temperature: null,
    createdAt: now,
  };
  await repository.saveAgent(agent);
  await repository.saveTopic({
    id: "topic_default",
    ownerType: "agent",
    ownerId: agent.id,
    title: "新的对话",
    turnIndex: 0,
    createdAt: now,
    updatedAt: now,
  });
}
