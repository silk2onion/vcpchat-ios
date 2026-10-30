import type { LogEntry } from "../domain";

export type ActivityKind = "log" | "approval" | "rag" | "thinking" | "agent" | "memory" | "dream" | "notification" | "error";
export const record = (v: unknown): Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
export const text = (v: unknown): string => typeof v === "string" ? v : typeof v === "number" ? String(v) : "";

export function activityPayload(entry: LogEntry): Record<string, unknown> {
  if (entry.payload) return entry.payload;
  try { return record(JSON.parse(entry.detail)); } catch { return { type: entry.title, message: entry.detail }; }
}

export function activityData(entry: LogEntry): Record<string, unknown> {
  const payload = activityPayload(entry);
  return { ...payload, ...record(payload.data) };
}

export function activityKind(entry: LogEntry): ActivityKind {
  const data = activityData(entry);
  const type = text(data.type);
  if (type === "tool_approval_request" || type === "tool_approval_response") return "approval";
  if (type === "RAG_RETRIEVAL_DETAILS" || Array.isArray(data.results)) return "rag";
  if (type === "META_THINKING_CHAIN") return "thinking";
  if (type === "AGENT_PRIVATE_CHAT_PREVIEW" || data.source === "AgentAssistant") return "agent";
  if (type === "AI_MEMO_RETRIEVAL" || type === "DailyNote") return "memory";
  if (type.startsWith("AGENT_DREAM_")) return "dream";
  if (/error|fail/i.test(type) || data.level === "error" || data.status === "error") return "error";
  if (type === "notification" || type === "daily_note_created" || type === "video_generation_status") return "notification";
  return "log";
}

export function approvalId(entry: LogEntry): string { return text(activityData(entry).requestId); }
export function approvalExpired(entry: LogEntry, now = Date.now()): boolean {
  const data = activityData(entry);
  const expiry = data.expiresAt ?? data.expireAt;
  const timestamp = typeof expiry === "number" ? expiry : typeof expiry === "string" ? Date.parse(expiry) : NaN;
  return Number.isFinite(timestamp) && timestamp <= now;
}
export function approvalResponse(requestId: string, approved: boolean, reason = "") {
  if (!requestId.trim()) throw new Error("审批缺少 requestId");
  return { type: "tool_approval_response", data: { requestId, approved, ...(reason.trim() ? { reason: reason.trim().slice(0, 1000) } : {}) } };
}

export function redactPayload(value: unknown, redact: (value: string) => string): unknown {
  if (typeof value === "string") return redact(value);
  if (Array.isArray(value)) return value.map((v) => redactPayload(v, redact));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [redact(k), redactPayload(v, redact)]));
  return value;
}

export function activityTitle(entry: LogEntry): string {
  const data = activityData(entry);
  switch (activityKind(entry)) {
    case "approval": return text(data.type) === "tool_approval_response" ? "审批回执" : text(data.toolName) || "工具审批";
    case "rag": return text(data.dbName) || "RAG 检索";
    case "thinking": return text(data.chainName ?? data.title) || "元思考链";
    case "agent": return text(data.agentName ?? data.sender ?? data.maid) || "Agent 会话";
    case "memory": return text(data.dbName ?? data.title ?? data.agentName) || "记忆检索";
    case "dream": return text(data.title ?? data.agentName) || "Agent 梦境";
    default: return text(data.title ?? data.message ?? data.toolName) || entry.title;
  }
}
