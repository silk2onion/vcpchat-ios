import type { ChatMessage, RegexRule } from "../domain";
import { createId } from "./ids";

export function compileRule(pattern: string): RegExp {
  const literal = pattern.match(/^\/([\s\S]*)\/([dgimsuvy]*)$/);
  return literal ? new RegExp(literal[1], literal[2]) : new RegExp(pattern, "g");
}

/** Desktop VChat measures depth by user/assistant turns, not individual messages. */
export function turnDepths(messages: Pick<ChatMessage, "id" | "role">[]): Map<string, number> {
  const depths = new Map<string, number>();
  let depth = 0;
  for (let i = messages.length - 1; i >= 0; i--, depth++) {
    depths.set(messages[i].id, depth);
    if (messages[i].role === "assistant" && messages[i - 1]?.role === "user") {
      depths.set(messages[--i].id, depth);
    }
  }
  return depths;
}

export function applyRules(text: string, rules: readonly RegexRule[], scope: "frontend" | "context", role: "user" | "assistant", depth = 0): string {
  let result = text;
  for (const rule of rules) {
    if (!rule.enabled || !rule.applyToRoles.includes(role)) continue;
    if (!(scope === "frontend" ? rule.applyToFrontend : rule.applyToContext)) continue;
    if (rule.minDepth >= 0 && depth < rule.minDepth) continue;
    if (rule.maxDepth >= 0 && depth > rule.maxDepth) continue;
    result = result.replace(compileRule(rule.findPattern), rule.replaceWith);
  }
  return result;
}

export function importRules(value: unknown): RegexRule[] {
  const values = Array.isArray(value) ? value : [value];
  return values.map((item) => {
    if (!item || typeof item !== "object") throw new Error("请选择 VChat 或 SillyTavern 的正则 JSON 文件");
    const r = item as Record<string, unknown>;
    const st = typeof r.scriptName === "string";
    const title = String(st ? r.scriptName : r.title ?? "").trim();
    const findPattern = String(st ? r.findRegex ?? "" : r.findPattern ?? "");
    if (!title || !findPattern) throw new Error("规则缺少名称或查找表达式");
    try { compileRule(findPattern); } catch (error) { throw new Error(`「${title}」表达式无效：${error instanceof Error ? error.message : error}`); }
    const roles = st
      ? (Array.isArray(r.placement) ? r.placement : []).map((p) => p === 1 ? "user" : p === 2 ? "assistant" : "")
      : (Array.isArray(r.applyToRoles) ? r.applyToRoles : ["assistant"]);
    return {
      id: createId("rule"), title, findPattern,
      replaceWith: String(st ? r.replaceString ?? "" : r.replaceWith ?? ""),
      applyToRoles: roles.filter((role): role is "user" | "assistant" => role === "user" || role === "assistant"),
      applyToFrontend: Boolean(st ? r.markdownOnly ?? true : r.applyToFrontend ?? true),
      applyToContext: Boolean(st ? r.promptOnly ?? false : r.applyToContext ?? false),
      minDepth: typeof r.minDepth === "number" ? r.minDepth : 0,
      maxDepth: typeof r.maxDepth === "number" ? r.maxDepth : -1,
      enabled: r.enabled !== false && r.disabled !== true,
    };
  });
}
