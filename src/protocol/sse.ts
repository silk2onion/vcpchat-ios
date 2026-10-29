export interface SseDelta {
  content: string;
  reasoning: string;
  error?: string;
}

export function extractSseJson(value: unknown): SseDelta {
  if (!value || typeof value !== "object") return { content: "", reasoning: "" };
  const record = value as Record<string, unknown>;
  const error = readError(record.error);
  const choice = Array.isArray(record.choices) ? (record.choices[0] as Record<string, unknown> | undefined) : undefined;
  const delta = asRecord(choice?.delta);
  const message = asRecord(choice?.message);
  const content =
    readText(delta?.content) || readText(message?.content) || readText(record.content) || readText(record.delta && asRecord(record.delta)?.content);
  const reasoning =
    readText(delta?.reasoning_content) ||
    readText(delta?.reasoning) ||
    readText(message?.reasoning_content) ||
    readText(message?.reasoning);
  return { content, reasoning, error };
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : undefined;
}

function readError(value: unknown): string | undefined {
  if (typeof value === "string" && value.trim()) return value.trim();
  const record = asRecord(value);
  if (!record) return undefined;
  if (typeof record.message === "string" && record.message.trim()) return record.message.trim();
  return undefined;
}

export function readText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value
    .map((part) => {
      if (typeof part === "string") return part;
      const record = asRecord(part);
      if (record?.type === "text" && typeof record.text === "string") return record.text;
      return "";
    })
    .join("");
}

export interface SseParser {
  push(chunk: string): void;
  finish(): void;
}

export function createSseParser(handlers: {
  onContent: (text: string) => void;
  onReasoning: (text: string) => void;
  onError: (message: string) => void;
  onDone: () => void;
}): SseParser {
  let buffer = "";
  let finished = false;
  const consumeLine = (line: string) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith(":")) return;
    if (!trimmed.toLowerCase().startsWith("data:")) return;
    const data = trimmed.slice(trimmed.indexOf(":") + 1).trim();
    if (!data) return;
    if (data === "[DONE]") {
      if (!finished) {
        finished = true;
        handlers.onDone();
      }
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(data);
    } catch {
      return;
    }
    const delta = extractSseJson(parsed);
    if (delta.error) handlers.onError(delta.error);
    if (delta.reasoning) handlers.onReasoning(delta.reasoning);
    if (delta.content) handlers.onContent(delta.content);
  };
  return {
    push(chunk: string) {
      buffer += chunk;
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop() ?? "";
      for (const line of lines) consumeLine(line);
    },
    finish() {
      if (buffer.trim()) consumeLine(buffer);
      buffer = "";
    },
  };
}
