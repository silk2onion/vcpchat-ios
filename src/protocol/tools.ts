export interface ResultField {
  key: string;
  value: string;
}

export interface DiaryEntry {
  mode: "create" | "update";
  agent: string;
  agentLabel: "Maid" | "Valet";
  title: string;
  date: string;
  folder: string;
  content: string;
  target: string;
  replace: string;
  tag: string;
}

export type Segment =
  | { type: "text"; text: string }
  | { type: "think"; text: string; closed: boolean; title?: string }
  | { type: "tool"; name: string; command: string; body: string; closed: boolean }
  | { type: "diary"; entry: DiaryEntry; closed: boolean }
  | { type: "result"; text: string; closed: boolean; toolName: string; status: string; ok: boolean | null; fields: ResultField[]; content: string }
  | { type: "summary"; items: string[]; closed: boolean }
  | { type: "divider"; role: "system" | "assistant" | "user"; end: boolean }
  | { type: "push"; text: string; closed: boolean };

const TOOL_START = "<<<[TOOL_REQUEST]>>>";
const TOOL_END = /<{2,4}\[END_TOOL_REQUEST\]>{2,4}/;
const RESULT_START = "[[VCP调用结果信息汇总:";
const RESULT_END = "VCP调用结果结束]]";
const NOTE_START = "<<<DailyNoteStart>>>";
const NOTE_END = "<<<DailyNoteEnd>>>";
const CHAIN_START = "[--- VCP元思考链";
const CHAIN_END = "[--- 元思考链结束 ---]";
const SUMMARY_START = "[本轮工具调用摘要:]";
const SUMMARY_END = "[本轮工具调用摘要结束]";
const PUSH_START = "<<<[DESKTOP_PUSH]>>>";
const PUSH_END = "<<<[DESKTOP_PUSH_END]>>>";
const DIVIDER = /^<<<\[(END_)?ROLE_DIVIDE_(SYSTEM|ASSISTANT|USER)\]>>>/;
const RESULT_TEXT_KEYS = new Set(["返回内容", "内容", "Result", "返回结果", "output"]);
const RESULT_KNOWN_KEYS = new Set(["工具名称", "执行状态", "命令", "参数", "可访问URL", "url", "image", ...RESULT_TEXT_KEYS]);

interface Fence {
  start: number;
  end: number;
}

function codeFences(text: string): Fence[] {
  const fences: Fence[] = [];
  let open: { start: number; marker: string; length: number } | null = null;
  let offset = 0;
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (open) {
      const close = line.match(/^ {0,3}(`+|~+)[ \t]*$/)?.[1];
      if (close && close[0] === open.marker && close.length >= open.length) {
        fences.push({ start: open.start, end: Math.min(text.length, offset + raw.length + 1) });
        open = null;
      }
    } else {
      const start = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      // CommonMark: backtick fence info strings cannot contain backticks.
      if (start && !(start[1][0] === "`" && start[2].includes("`"))) {
        open = { start: offset, marker: start[1][0], length: start[1].length };
      }
    }
    offset += raw.length + 1;
  }
  if (open) fences.push({ start: open.start, end: text.length });
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

const OPEN_MARK = "(?:「始(?:escape)?」|\\{始(?:escape)?\\})";
const CLOSE_MARK = "(?:「末(?:ESCAPE|escape)?」|\\{末(?:ESCAPE|escape)?\\})";

function extractBraced(body: string, field: string): string | null {
  const braced = body.match(new RegExp(`(?:^|[\\s,，])${field}\\s*[:：]\\s*${OPEN_MARK}([\\s\\S]*?)${CLOSE_MARK}`, "i"));
  return braced?.[1] != null ? braced[1].trim() : null;
}

function extractPlain(body: string, field: string): string {
  const plain = body.match(new RegExp(`(?:^|\\n)\\s*${field}\\s*[:：]\\s*([^\\n,]+)`, "i"));
  return plain?.[1]?.trim() ?? "";
}

export function extractMarkedField(body: string, field: string): string {
  return extractBraced(body, field) ?? extractPlain(body, field);
}

/** Same field, but an unclosed 「始」 while streaming yields everything written so far. */
function extractStreamingField(body: string, field: string): string {
  const closed = extractBraced(body, field);
  if (closed !== null) return closed;
  const open = body.match(new RegExp(`(?:^|[\\s,，])${field}\\s*[:：]\\s*${OPEN_MARK}([\\s\\S]*)$`, "i"));
  return open ? open[1].trim() : extractPlain(body, field);
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

function diaryAgent(body: string): { agent: string; agentLabel: "Maid" | "Valet" } {
  const valet = extractMarkedField(body, "valet") || extractMarkedField(body, "valetName");
  if (valet) return { agent: valet, agentLabel: "Valet" };
  return { agent: extractMarkedField(body, "maid") || extractMarkedField(body, "maidName"), agentLabel: "Maid" };
}

/** DailyNote tool requests render as a diary card instead of a generic tool card. */
export function diaryFromTool(name: string, command: string, body: string): DiaryEntry | null {
  if (name.trim().toLowerCase() !== "dailynote") return null;
  const normalized = command.trim().toLowerCase();
  const content = extractStreamingField(body, "Content");
  const target = extractStreamingField(body, "target");
  const replace = extractStreamingField(body, "replace");
  const update = normalized === "update" || (!normalized && Boolean(target && replace));
  const create = !update && (normalized === "create" || (!normalized && Boolean(content)));
  if (!update && !create) return null;
  const agent = diaryAgent(body);
  return {
    mode: update ? "update" : "create",
    ...agent,
    title: extractMarkedField(body, "fileName") || `${agent.agentLabel}'s Diary`,
    date: extractMarkedField(body, "Date"),
    folder: extractMarkedField(body, "folder"),
    content: update ? "" : content,
    target: update ? target : "",
    replace: update ? replace : "",
    tag: extractMarkedField(body, "Tag"),
  };
}

function legacyDiary(raw: string): DiaryEntry {
  const content = raw.trim();
  const agent = content.match(/Maid:\s*([^\n\r]*)/)?.[1]?.trim() ?? "";
  return {
    mode: "create",
    agent,
    agentLabel: "Maid",
    title: "Maid's Diary",
    date: content.match(/Date:\s*([^\n\r]*)/)?.[1]?.trim() ?? "",
    folder: "",
    content: content.match(/Content:\s*([\s\S]*)/)?.[1]?.trim() ?? content,
    target: "",
    replace: "",
    tag: "",
  };
}

export function parseResultFields(text: string): { toolName: string; status: string; ok: boolean | null; fields: ResultField[]; content: string } {
  const fields: ResultField[] = [];
  let current: ResultField | null = null;
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^\s*-?\s*([^:：\n]{1,24}?)\s*[:：]\s?(.*)$/);
    const key = match?.[1]?.trim() ?? "";
    if (match && (RESULT_KNOWN_KEYS.has(key) || /^\s*-\s/.test(line))) {
      current = { key, value: match[2] ?? "" };
      fields.push(current);
      continue;
    }
    if (current) current.value += `\n${line}`;
  }
  for (const field of fields) field.value = field.value.trim();
  const find = (key: string) => fields.find((field) => field.key === key)?.value ?? "";
  const status = find("执行状态");
  const ok = !status ? null : /❌|error|fail|失败/i.test(status) ? false : /✅|success|成功/i.test(status);
  const content = fields.find((field) => RESULT_TEXT_KEYS.has(field.key))?.value ?? (fields.length ? "" : text);
  return {
    toolName: find("工具名称"),
    status,
    ok,
    fields: fields.filter((field) => field.key !== "工具名称" && field.key !== "执行状态" && !RESULT_TEXT_KEYS.has(field.key)),
    content,
  };
}

type Parsed = { segment: Segment; next: number } | { segment: Segment; next: null } | null;

const OPENERS: { marker: string; parse: (text: string, at: number) => Parsed }[] = [
  { marker: "<think>", parse: (text, at) => parseThink(text, at, "<think>", "</think>") },
  { marker: "<thinking>", parse: (text, at) => parseThink(text, at, "<thinking>", "</thinking>") },
  { marker: TOOL_START, parse: parseTool },
  { marker: RESULT_START, parse: parseResult },
  { marker: NOTE_START, parse: parseNote },
  { marker: CHAIN_START, parse: parseChain },
  { marker: SUMMARY_START, parse: parseSummary },
  { marker: PUSH_START, parse: parsePush },
  { marker: "<<<[ROLE_DIVIDE_", parse: parseDivider },
  { marker: "<<<[END_ROLE_DIVIDE_", parse: parseDivider },
];

function parseThink(text: string, at: number, open: string, close: string): Parsed {
  const end = text.indexOf(close, at + open.length);
  if (end < 0) return { segment: { type: "think", text: text.slice(at + open.length), closed: false }, next: null };
  return { segment: { type: "think", text: text.slice(at + open.length, end).trim(), closed: true }, next: end + close.length };
}

function parseTool(text: string, at: number): Parsed {
  const bodyFrom = at + TOOL_START.length;
  const end = findToolEnd(text, bodyFrom);
  const body = text.slice(bodyFrom, end ? end.index : undefined).trim();
  const name = extractMarkedField(body, "tool_name") || "工具调用";
  const command = extractMarkedField(body, "command");
  const diary = diaryFromTool(name, command, body);
  const segment: Segment = diary
    ? { type: "diary", entry: diary, closed: Boolean(end) }
    : { type: "tool", name, command, body, closed: Boolean(end) };
  return { segment, next: end ? end.index + end.length : null };
}

function parseResult(text: string, at: number): Parsed {
  const bodyFrom = at + RESULT_START.length;
  const end = findResultEnd(text, bodyFrom);
  const body = text.slice(bodyFrom, end < 0 ? undefined : end).trim();
  return { segment: { type: "result", text: body, closed: end >= 0, ...parseResultFields(body) }, next: end < 0 ? null : end + RESULT_END.length };
}

function parseNote(text: string, at: number): Parsed {
  const bodyFrom = at + NOTE_START.length;
  const end = text.indexOf(NOTE_END, bodyFrom);
  const body = text.slice(bodyFrom, end < 0 ? undefined : end);
  return { segment: { type: "diary", entry: legacyDiary(body), closed: end >= 0 }, next: end < 0 ? null : end + NOTE_END.length };
}

function parseChain(text: string, at: number): Parsed {
  const header = text.slice(at).match(/^\[--- VCP元思考链(?::\s*"([^"]*)")?\s*---\][ \t]*\r?\n?/);
  if (!header) return null;
  const bodyFrom = at + header[0].length;
  const end = text.indexOf(CHAIN_END, bodyFrom);
  const title = header[1]?.trim() || "元思考链";
  if (end < 0) return { segment: { type: "think", title, text: text.slice(bodyFrom), closed: false }, next: null };
  return { segment: { type: "think", title, text: text.slice(bodyFrom, end).trim(), closed: true }, next: end + CHAIN_END.length };
}

function parseSummary(text: string, at: number): Parsed {
  const bodyFrom = at + SUMMARY_START.length;
  const end = text.indexOf(SUMMARY_END, bodyFrom);
  const items = text
    .slice(bodyFrom, end < 0 ? undefined : end)
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*[-*•\d.、]+\s*/, "").trim())
    .filter(Boolean);
  return { segment: { type: "summary", items, closed: end >= 0 }, next: end < 0 ? null : end + SUMMARY_END.length };
}

function parsePush(text: string, at: number): Parsed {
  const bodyFrom = at + PUSH_START.length;
  const end = text.indexOf(PUSH_END, bodyFrom);
  return { segment: { type: "push", text: text.slice(bodyFrom, end < 0 ? undefined : end).trim(), closed: end >= 0 }, next: end < 0 ? null : end + PUSH_END.length };
}

function parseDivider(text: string, at: number): Parsed {
  const match = text.slice(at).match(DIVIDER);
  if (!match) return null;
  const role = match[2].toLowerCase() as "system" | "assistant" | "user";
  return { segment: { type: "divider", role, end: Boolean(match[1]) }, next: at + match[0].length };
}

export function parseSegments(source: string): Segment[] {
  const text = source ?? "";
  const fences = codeFences(text);
  const segments: Segment[] = [];
  let cursor = 0;
  let textFrom = 0;
  while (cursor < text.length) {
    let best = -1;
    let opener: (typeof OPENERS)[number] | null = null;
    for (const candidate of OPENERS) {
      const index = findMarker(text, candidate.marker, cursor, fences);
      if (index >= 0 && (best < 0 || index < best)) {
        best = index;
        opener = candidate;
      }
    }
    if (!opener || best < 0) break;
    const parsed = opener.parse(text, best);
    if (!parsed) {
      cursor = best + opener.marker.length;
      continue;
    }
    pushText(segments, text.slice(textFrom, best));
    segments.push(parsed.segment);
    if (parsed.next === null) {
      textFrom = text.length;
      break;
    }
    cursor = parsed.next;
    textFrom = parsed.next;
  }
  pushText(segments, text.slice(textFrom));
  return segments.filter((segment) => segment.type !== "text" || segment.text.trim().length > 0);
}

function pushText(segments: Segment[], value: string) {
  if (!value) return;
  segments.push({ type: "text", text: value });
}
