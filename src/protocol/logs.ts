export function summarizePayload(payload: unknown): { title: string; detail: string } {
  if (typeof payload === "string") {
    return { title: clipLine(payload, 80) || "消息", detail: clipRaw(payload, 4000) };
  }
  if (payload && typeof payload === "object") {
    const record = payload as Record<string, unknown>;
    const titleSource = record.type ?? record.message ?? record.level ?? record.source ?? "消息";
    const title = clipLine(typeof titleSource === "string" ? titleSource : JSON.stringify(titleSource), 80);
    return { title: title || "消息", detail: clipRaw(JSON.stringify(payload, null, 2), 4000) };
  }
  return { title: "消息", detail: clipRaw(String(payload), 4000) };
}

function clipLine(value: string, max: number): string {
  const trimmed = value.replace(/\s+/g, " ").trim();
  return trimmed.length > max ? `${trimmed.slice(0, max)}…` : trimmed;
}

function clipRaw(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, max)}…` : value;
}
