import type { Agent, Group, ChatMessage, Topic } from "../domain";
import {
  identityKey,
  topicKey,
  localId,
  type Json,
  type Shadow,
  type Snapshot,
  type SyncProfile,
  type WireMessage,
} from "./types";
import {
  computeAggregatedHash,
  computeDtoHash,
  computeMessageFingerprint,
  computeMessageLeafHash,
  computeTopicLeafHash,
} from "./upstream/hash.js";
import { canonicalizeMessage } from "./upstream/canonical.js";
export const AGENT_FIELDS = [
  "name",
  "systemPrompt",
  "model",
  "temperature",
  "contextTokenLimit",
  "maxOutputTokens",
  "streamOutput",
];
export const GROUP_FIELDS = [
  "name",
  "members",
  "mode",
  "memberTags",
  "groupPrompt",
  "invitePrompt",
  "useUnifiedModel",
  "unifiedModel",
  "enableContextMessageWindow",
  "contextMessageWindowSize",
  "tagMatchMode",
  "createdAt",
];
export const string = (v: unknown, fallback = "") =>
  typeof v === "string" ? v : fallback;
export const time = (v: unknown, fallback = 0) =>
  typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : fallback;
export function object(v: unknown): Json {
  if (!v || typeof v !== "object" || Array.isArray(v))
    throw new Error("同步响应对象无效");
  return v as Json;
}
export function fields(e: Shadow): string[] {
  return e.entityType === "owner"
    ? e.ownerType === "agent"
      ? AGENT_FIELDS
      : GROUP_FIELDS
    : e.ownerType === "agent"
      ? ["id", "name", "createdAt", "locked", "unread"]
      : ["id", "name", "createdAt"];
}
export const entityId = (p: SyncProfile, e: Shadow) =>
  e.localId ??
  localId(
    p,
    e.entityType === "owner" ? e.ownerType : "topic",
    e.topicId ?? e.ownerId,
    e.entityType === "topic" ? `${e.ownerType}:${e.ownerId}` : "",
  );
export function managed(all: Snapshot, p: SyncProfile): Snapshot {
  const owners = new Set(
    [...all.agents, ...all.groups]
      .filter((r) => r.id.startsWith(`sync:${p.id}:`))
      .map((r) => r.id),
  );
  const topics = all.topics.filter((r) => owners.has(r.ownerId));
  const ids = new Set(topics.map((r) => r.id));
  return {
    agents: all.agents.filter((r) => owners.has(r.id)),
    groups: all.groups.filter((r) => owners.has(r.id)),
    topics,
    messages: all.messages.filter((r) => ids.has(r.topicId)),
  };
}
export function groupMode(v: unknown): Group["mode"] {
  return v === "sequential" ? "all" : v === "random" ? "random" : "invite_only";
}
export function toLocal(p: SyncProfile, extras?: Snapshot): Snapshot {
  const out: Snapshot = { agents: [], groups: [], topics: [], messages: [] };
  const agents = new Map<string, string>();
  for (const e of Object.values(p.entities))
    if (
      e.entityType === "owner" &&
      e.ownerType === "agent" &&
      e.deletedAt === undefined
    )
      agents.set(e.ownerId, entityId(p, e));
  for (const e of Object.values(p.entities)) {
    if (e.deletedAt !== undefined) continue;
    const d = e.data,
      id = entityId(p, e);
    const avatarRecord = p.avatars[`${e.ownerType}\0${e.ownerId}`];
    const avatar = avatarRecord?.image;
    if (e.entityType === "owner" && e.ownerType === "agent")
      out.agents.push({
        ...extras?.agents.find((r) => r.id === id),
        id,
        name: string(d.name, "未命名 Agent"),
        systemPrompt: string(d.systemPrompt),
        model: string(d.model),
        temperature: typeof d.temperature === "number" ? d.temperature : null,
        createdAt: time(d.createdAt, e.updatedAt),
        ...(avatarRecord ? { avatarUrl: avatar ?? "" } : {}),
      });
    else if (e.entityType === "owner")
      out.groups.push({
        ...extras?.groups.find((r) => r.id === id),
        id,
        name: string(d.name, "未命名群组"),
        memberIds: (Array.isArray(d.members) ? d.members : [])
          .map((v) => agents.get(string(v)))
          .filter((v): v is string => Boolean(v)),
        mode: groupMode(d.mode),
        createdAt: time(d.createdAt, e.updatedAt),
        systemPrompt: string(d.groupPrompt),
        unifiedModel: d.useUnifiedModel === true ? string(d.unifiedModel) : "",
        ...(avatarRecord ? { avatarUrl: avatar ?? "" } : {}),
      });
    else {
      const owner =
        p.entities[
          identityKey({
            entityType: "owner",
            ownerType: e.ownerType,
            ownerId: e.ownerId,
          })
        ];
      if (!owner || owner.deletedAt !== undefined) continue;
      out.topics.push({
        id,
        ownerType: e.ownerType,
        ownerId: entityId(p, owner),
        title: string(d.name, "同步会话"),
        createdAt: time(d.createdAt, e.updatedAt),
        updatedAt: Math.max(e.updatedAt,(p.messages[topicKey(e)]??[]).reduce((latest,message)=>Math.max(latest,message.timestamp),0)),
        turnIndex: 0,
      });
      for (const m of p.messages[topicKey(e)] ?? []) {
        const old = extras?.messages.find(
          (r) =>
            r.id === (m.localId ?? localId(p, "message", m.id, topicKey(e))),
        );
        const row: ChatMessage = {
          ...old,
          id: m.localId ?? localId(p, "message", m.id, topicKey(e)),
          topicId: id,
          role: m.role === "user" ? "user" : "assistant",
          ...(m.role !== "user" && m.role !== "assistant"
            ? { originalRole: m.role, syncNotice: `原消息类型：${m.role}` }
            : {}),
          content: m.content,
          reasoning: old?.reasoning ?? "",
          createdAt: m.timestamp,
          status: old?.content === m.content ? old.status : "complete",
          authorName: string(m.name),
          agentId: agents.get(string(m.agentId)),
          attachments: (m.attachments ?? []).map((a, i) => ({
            id: string(a.hash, `${m.id}-${i}`),
            name: string(a.name, "桌面附件"),
            mime: string(a.type, "application/octet-stream"),
            kind: string(a.type).startsWith("image/")
              ? ("image" as const)
              : ("text" as const),
            hash: string(a.hash),
            desktopOnly: true,
            ...(typeof a.extractedText === "string"
              ? { text: a.extractedText }
              : {}),
          })),
        };
        // A known local file remains usable when only its portable metadata changes.
        row.attachments = row.attachments.map((a) => {
          const kept = old?.attachments.find(
            (v) => a.hash && v.hash === a.hash && !v.desktopOnly,
          );
          return kept ? { ...a, ...kept } : a;
        });
        out.messages.push(row);
      }
    }
  }
  return out;
}
export function refreshRoots(p: SyncProfile) {
  for (const e of Object.values(p.entities))
    if (e.entityType === "topic" && e.deletedAt === undefined)
      e.contentHash = computeAggregatedHash(
        (p.messages[topicKey(e)] ?? []).map((m) =>
          computeMessageLeafHash(m.id, m.contentHash),
        ),
      );
  for (const e of Object.values(p.entities))
    if (e.entityType === "owner" && e.deletedAt === undefined)
      e.contentHash = computeAggregatedHash(
        Object.values(p.entities)
          .filter(
            (t) =>
              t.entityType === "topic" &&
              t.ownerType === e.ownerType &&
              t.ownerId === e.ownerId &&
              t.deletedAt === undefined,
          )
          .map((t) =>
            computeTopicLeafHash(t.topicId!, t.configHash, t.contentHash),
          ),
      );
}
export function overlayLocal(
  p: SyncProfile,
  local: Snapshot,
  now = Date.now(),
  versions: Record<string, number> = {},
): Record<string, { msgId: string; deletedAt: number }[]> {
  const baseline = toLocal(p);
  const tombstones: Record<string, { msgId: string; deletedAt: number }[]> = {};
  const ownerByLocal = new Map(
    Object.values(p.entities)
      .filter((e) => e.entityType === "owner")
      .map((e) => [entityId(p, e), e]),
  );
  const remoteAgents = new Map(
    [...ownerByLocal]
      .filter(([, e]) => e.ownerType === "agent")
      .map(([id, e]) => [id, e.ownerId]),
  );
  for (const e of Object.values(p.entities)) {
    if (e.deletedAt !== undefined) continue;
    const id = entityId(p, e);
    const before =
      e.entityType === "owner"
        ? e.ownerType === "agent"
          ? baseline.agents.find((r) => r.id === id)
          : baseline.groups.find((r) => r.id === id)
        : baseline.topics.find((r) => r.id === id);
    const current =
      e.entityType === "owner"
        ? e.ownerType === "agent"
          ? local.agents.find((r) => r.id === id)
          : local.groups.find((r) => r.id === id)
        : local.topics.find((r) => r.id === id);
    if (!current) {
      e.deletedAt = now;
      continue;
    }
    const editedAt =
      versions[
        `${e.entityType === "topic" ? "topics" : e.ownerType === "agent" ? "agents" : "groups"}\0${id}`
      ] ?? now;
    const next = { ...e.data };
    if (e.entityType === "topic") {
      next.name = (current as Topic).title;
    } else if (e.ownerType === "agent") {
      const a = current as Agent;
      next.name = a.name;
      next.systemPrompt = a.systemPrompt;
      next.model = a.model;
      next.temperature = a.temperature ?? 1;
    } else {
      const g = current as Group;
      const b = before as Group | undefined;
      next.name = g.name;
      if (JSON.stringify(g.memberIds) !== JSON.stringify(b?.memberIds))
        next.members = g.memberIds.map((id) => {
          const remote = remoteAgents.get(id);
          if (!remote)
            throw new Error(
              "群组含未加入此同步来源的成员，未写回；请先在桌面加入成员",
            );
          return remote;
        });
      if (g.mode !== b?.mode) {
        if (g.mode === "rotate" || g.mode === "mention")
          throw new Error(
            "此群组发言模式不能写回桌面，请选依次、随机或仅点名发言",
          );
        next.mode = g.mode === "all" ? "sequential" : g.mode;
      }
    }
    const hash = computeDtoHash(next, fields(e));
    if (hash !== e.configHash) {
      e.data = next;
      e.configHash = hash;
      e.updatedAt = editedAt;
    }
  }
  for (const t of local.topics)
    if (
      !Object.values(p.entities).some(
        (e) => e.entityType === "topic" && entityId(p, e) === t.id,
      )
    ) {
      const owner = ownerByLocal.get(t.ownerId);
      if (!owner || owner.deletedAt !== undefined) continue;
      const e: Shadow = {
        entityType: "topic",
        ownerType: owner.ownerType,
        ownerId: owner.ownerId,
        topicId: t.id,
        localId: t.id,
        data: {
          id: t.id,
          name: t.title,
          createdAt: t.createdAt,
          ownerId: owner.ownerId,
          ...(owner.ownerType === "agent"
            ? { locked: false, unread: false }
            : {}),
        },
        configHash: "",
        contentHash: "",
        updatedAt: now,
      };
      e.configHash = computeDtoHash(e.data, fields(e));
      p.entities[identityKey(e)] = e;
    }
  for (const e of Object.values(p.entities))
    if (e.entityType === "topic" && e.deletedAt === undefined) {
      const key = topicKey(e),
        id = entityId(p, e),
        previous = p.messages[key] ?? [];
      const rows = local.messages.filter((r) => r.topicId === id);
      const next: WireMessage[] = [];
      for (const r of rows) {
        if (r.status === "streaming")
          throw new Error("请等待正在生成的回复结束后同步");
        const old = previous.find(
          (m) => (m.localId ?? localId(p, "message", m.id, key)) === r.id,
        );
        const before = baseline.messages.find((m) => m.id === r.id);
        if (
          old &&
          before &&
          r.content === before.content &&
          r.reasoning === before.reasoning &&
          r.authorName === before.authorName &&
          JSON.stringify(r.attachments.map((a) => a.hash)) ===
            JSON.stringify(before.attachments.map((a) => a.hash))
        ) {
          next.push(old);
          continue;
        }
        const attachments = r.attachments.map((a) => {
          if (!a.hash)
            throw new Error("新附件尚未登记文件身份，请从文件页导入后再同步");
          return {
            name: a.name,
            type: a.mime,
            size: 0,
            hash: a.hash,
            ...(a.text ? { extractedText: a.text } : {}),
          };
        });
        const raw = {
          ...(old ?? {}),
          id: old?.id ?? r.id,
          role: r.originalRole ?? r.role,
          content: r.reasoning
            ? `<think>${r.reasoning}</think>\n${r.content}`
            : r.content,
          timestamp: r.createdAt,
          updatedAt: now,
          topicId: e.topicId,
          ...(r.authorName ? { name: r.authorName } : {}),
          ...(r.agentId && remoteAgents.get(r.agentId)
            ? { agentId: remoteAgents.get(r.agentId) }
            : {}),
          ...(attachments.length ? { attachments } : {}),
        };
        const m = canonicalizeMessage(raw, e.topicId!);
        m.updatedAt = versions[`messages\0${r.id}`] ?? now;
        m.localId = r.id;
        m.contentHash = computeMessageFingerprint(m);
        next.push(m);
      }
      tombstones[key] = previous
        .filter(
          (m) =>
            !rows.some(
              (r) => r.id === (m.localId ?? localId(p, "message", m.id, key)),
            ),
        )
        .map((m) => ({ msgId: m.id, deletedAt: now }));
      p.messages[key] = next;
    }
  refreshRoots(p);
  return tombstones;
}
