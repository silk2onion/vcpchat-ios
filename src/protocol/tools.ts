export type Segment =
  | { type: "text"; text: string }
  | { type: "think"; text: string; closed: boolean }
  | { type: "tool"; name: string; command: string; body: string; closed: boolean }
  | { type: "result"; text: string; closed: boolean };

const TOOL_START = "<<<[TOOL_REQUEST]>>>";
const TOOL_END = /<{2,4}\[END_TOOL_REQUEST\]>{2,4}/;
const RESULT_START = "[[VCP调用结果信息汇总:";
const RESULT_END = "VCP调用结果结束]]";

interface Fence {
  start: number;
  end: number;
}

function codeFences(text: string): Fence[] {
  const fences: Fence[] = [];
  const pattern = /```[\s\S]*?(?:```|$)/g;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text))) {
    fences.push({ start: match.index, end: match.index + match[0].length });
    if (match.index === pattern.lastIndex) pattern.lastIndex += 1;
  }
  return fences;
}

function insideFence(index: number, fences: Fence[]): boolean {
  return fences.some((fence) => index >= fence.start && index < fence.end);
}

function findMarker(text: string, marker: string, from: number, fences: Fence[]): number {
  let cursor = from;
  while (cursor < text.length) {
    const index = text.indexOf(marker, cursor);
    if (index < 0) return -1;
    const wrapped = text[index - 1] === "`" || text[index + marker.length] === "`";
    if (!wrapped && !insideFence(index, fences)) return index;
    cursor = index + marker.length;
  }
  return -1;
}

export function extractMarkedField(body: string, field: string): string {
  const brace = new RegExp(
    `${field}\\s*[:：]\\s*(?:「始(?:escape)?」|\\{始(?:escape)?\\})([\\s\\S]*?)(?:「末(?:ESCAPE|escape)?」|\\{末(?:ESCAPE|escape)?\\})`,
    "i",
  );
  const braced = body.match(brace);
  if (braced?.[1] != null) return braced[1].trim();
  const plain = body.match(new RegExp(`(?:^|\\n)\\s*${field}\\s*[:：]\\s*([^\\n,]+)`, "i"));
  return plain?.[1]?.trim() ?? "";
}

function findToolEnd(text: string, from: number): { index: number; length: number } | null {
  const slice = text.slice(from);
  const match = TOOL_END.exec(slice);
  if (!match) return null;
  return { index: from + match.index, length: match[0].length };
}

function findResultEnd(text: string, contentFrom: number): number {
  let depth = 1;
  let cursor = contentFrom;
  while (cursor < text.length) {
    const nextStart = text.indexOf(RESULT_START, cursor);
    const nextEnd = text.indexOf(RESULT_END, cursor);
    if (nextEnd < 0) return -1;
    if (nextStart >= 0 && nextStart < nextEnd) {
      depth += 1;
      cursor = nextStart + RESULT_START.length;
      continue;
    }
    depth -= 1;
    if (depth === 0) return nextEnd;
    cursor = nextEnd + RESULT_END.length;
  }
  return -1;
}

export function parseSegments(source: string): Segment[] {
  const text = source ?? "";
  const fences = codeFences(text);
  const segments: Segment[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const think = findMarker(text, "<think>", cursor, fences);
    const thinking = findMarker(text, "<thinking>", cursor, fences);
    const tool = findMarker(text, TOOL_START, cursor, fences);
    const result = findMarker(text, RESULT_START, cursor, fences);
    const candidates = [think, thinking, tool, result].filter((index) => index >= 0);
    if (!candidates.length) {
      pushText(segments, text.slice(cursor));
      break;
    }
    const next = Math.min(...candidates);
    if (next > cursor) pushText(segments, text.slice(cursor, next));
    if (next === think || next === thinking) {
      const open = text.startsWith("<thinking>", next) ? "<thinking>" : "<think>";
      const close = open === "<thinking>" ? "</thinking>" : "</think>";
      const end = text.indexOf(close, next + open.length);
      if (end < 0) {
        segments.push({ type: "think", text: text.slice(next + open.length), closed: false });
        break;
      }
      segments.push({ type: "think", text: text.slice(next + open.length, end).trim(), closed: true });
      cursor = end + close.length;
      continue;
    }
    if (next === tool) {
      const bodyFrom = next + TOOL_START.length;
      const end = findToolEnd(text, bodyFrom);
      const body = text.slice(bodyFrom, end ? end.index : undefined).trim();
      segments.push({
        type: "tool",
        name: extractMarkedField(body, "tool_name") || "工具调用",
        command: extractMarkedField(body, "command"),
        body,
        closed: Boolean(end),
      });
      if (!end) break;
      cursor = end.index + end.length;
      continue;
    }
    const bodyFrom = next + RESULT_START.length;
    const end = findResultEnd(text, bodyFrom);
    segments.push({
      type: "result",
      text: text.slice(bodyFrom, end < 0 ? undefined : end).trim(),
      closed: end >= 0,
    });
    if (end < 0) break;
    cursor = end + RESULT_END.length;
  }
  return segments.filter((segment) => segment.type !== "text" || segment.text.trim().length > 0);
}

function pushText(segments: Segment[], value: string) {
  if (!value) return;
  segments.push({ type: "text", text: value });
}
