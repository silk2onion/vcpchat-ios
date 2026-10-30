import type { Agent, ChatMessage, Group, Settings } from "../domain";
import { LIMITS } from "../domain";
import { applyRules, turnDepths } from "./regex";

export interface ApiContentPart {
  type: "text" | "image_url";
  text?: string;
  image_url?: { url: string };
}

export interface ApiMessage {
  role: "system" | "user" | "assistant";
  content: string | ApiContentPart[];
}

export function resolveModel(agent: Agent, settings: Settings): string {
  return agent.model.trim() || settings.defaultModel.trim();
}

export function buildRequestBody(settings: Settings, agent: Agent, messages: ApiMessage[]): string {
  const model = resolveModel(agent, settings);
  if (!model) throw new Error("请先在设置或助手里填写模型名");
  const payload: Record<string, unknown> = {
    model,
    stream: true,
    messages,
  };
  if (settings.sendTemperature) {
    payload.temperature = agent.temperature ?? settings.temperature;
  }
  return JSON.stringify(payload);
}

export function toApiMessages(options: {
  settings: Settings;
  agent: Agent;
  group?: Group | null;
  messages: ChatMessage[];
}): ApiMessage[] {
  const { settings, agent, group, messages } = options;
  const system = systemPrompt(settings, agent, group);
  const window = messages.slice(-LIMITS.historyMessages);
  const lastUser = [...window].reverse().find((message) => message.role === "user");
  const api: ApiMessage[] = [];
  const depths = turnDepths(window);
  const rules = [...(settings.regexRules ?? []), ...(agent.regexRules ?? [])];
  if (system) api.push({ role: "system", content: system });
  for (const message of window) {
    if (message.originalRole && !["user","assistant"].includes(message.originalRole)) continue;
    if (message.role === "assistant" && !message.content.trim()) continue;
    const transformed = { ...message, content: applyRules(message.content, rules, "context", message.role, depths.get(message.id) ?? 0) };
    if (message.role === "user") {
      const includeFiles = message.id === lastUser?.id;
      api.push({ role: "user", content: userContent(transformed, includeFiles) });
      continue;
    }
    const speaker = message.authorName?.trim();
    const content = group && speaker ? `【${speaker}】\n${transformed.content}` : transformed.content;
    api.push({ role: "assistant", content });
  }
  return api;
}

function systemPrompt(settings: Settings, agent: Agent, group?: Group | null): string {
  const lines: string[] = [];
  if (settings.userName.trim()) lines.push(`用户名叫「${settings.userName.trim()}」。`);
  if (group) {
    if (group.systemPrompt?.trim()) lines.push(group.systemPrompt.trim());
    lines.push(`你正在群组「${group.name}」里发言。你的名字是「${agent.name}」。只以你自己的身份回复，不要代替其他成员说话。`);
  }
  if (agent.systemPrompt.trim()) lines.push(agent.systemPrompt.trim());
  return lines.join("\n\n");
}

export function userContent(message: ChatMessage, includeFiles: boolean): string | ApiContentPart[] {
  const text = message.content.trim();
  const files = includeFiles ? message.attachments : [];
  if (!files.length) return message.content;
  const parts: ApiContentPart[] = [];
  const textBlocks = [text];
  for (const file of files) {
    if (file.kind === "text" && file.text) {
      textBlocks.push(`附件 ${file.name}:\n${file.text}`);
    }
  }
  const merged = textBlocks.filter(Boolean).join("\n\n");
  if (merged) parts.push({ type: "text", text: merged });
  for (const file of files) {
    if (file.kind === "image" && file.dataUrl) {
      parts.push({ type: "image_url", image_url: { url: file.dataUrl } });
    }
  }
  if (!parts.length) return message.content;
  if (parts.length === 1 && parts[0].type === "text") return parts[0].text ?? "";
  return parts;
}

export function attachmentKind(file: { name: string; type: string; size: number }): "image" | "text" {
  const name = file.name.toLowerCase();
  const type = file.type.toLowerCase();
  if (type === "image/svg+xml" || name.endsWith(".svg")) {
    throw new Error("不接受 SVG 附件");
  }
  if (type.startsWith("image/")) {
    if (file.size > LIMITS.maxImageBytes) throw new Error(`${file.name} 超过 1.5MB`);
    return "image";
  }
  const textLike =
    type.startsWith("text/") ||
    type === "application/json" ||
    type === "application/xml" ||
    /\.(txt|md|json|csv|log|xml|yaml|yml)$/.test(name);
  if (!textLike) throw new Error(`${file.name} 不是图片或文本`);
  if (file.size > LIMITS.maxTextBytes) throw new Error(`${file.name} 超过 200KB`);
  return "text";
}

export function assertAttachmentCount(current: number, adding: number) {
  if (current + adding > LIMITS.maxAttachments) {
    throw new Error(`最多 ${LIMITS.maxAttachments} 个附件`);
  }
}
