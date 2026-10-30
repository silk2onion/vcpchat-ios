import type { Agent, Group } from "../domain";

export function selectSpeakers(group: Group, agents: Agent[], userText: string, turnIndex = 0): Agent[] {
  const members = group.memberIds
    .map((id) => agents.find((agent) => agent.id === id))
    .filter((agent): agent is Agent => Boolean(agent));
  if (!members.length) return [];
  const mentioned = extractMentions(userText, members);
  if (mentioned.length) return mentioned;
  if (group.mode === "invite_only") return [];
  if (group.mode === "random") return [members[Math.floor(Math.random() * members.length)]];
  if (group.mode === "all") return members;
  const index = Math.abs(Math.trunc(turnIndex)) % members.length;
  return [members[index]];
}

export function extractMentions(text: string, agents: Agent[]): Agent[] {
  const ordered = [...agents].sort((a, b) => b.name.length - a.name.length);
  const found: Agent[] = [];
  let rest = text;
  for (const agent of ordered) {
    const name = agent.name.trim();
    if (!name) continue;
    const pattern = new RegExp(`@${escapeRegExp(name)}(?=\\s|$|[，。,.!！?？])`);
    if (pattern.test(rest)) {
      found.push(agent);
      rest = rest.replace(pattern, " ");
    }
  }
  return found;
}

export function nextDelay(currentMs: number): number {
  if (!Number.isFinite(currentMs) || currentMs < 1000) return 1000;
  return Math.min(currentMs * 2, 30_000);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
