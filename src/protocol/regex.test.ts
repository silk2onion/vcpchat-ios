import { describe, expect, test } from "vitest";
import { defaultSettings, type Agent, type ChatMessage, type RegexRule } from "../domain";
import { toApiMessages } from "./messages";
import { applyRules, compileRule, importRules, turnDepths } from "./regex";
const rule = (patch: Partial<RegexRule> = {}): RegexRule => ({ id: "r", title: "称呼", findPattern: "/\\{\\{user\\}\\}/g", replaceWith: "丝巾", enabled: true, applyToRoles: ["assistant"], applyToFrontend: true, applyToContext: false, minDepth: 0, maxDepth: -1, ...patch });
describe("VChat regex compatibility", () => {
  test("supports JS literal flags, raw global patterns and capture groups", () => {
    expect("a1 A2".replace(compileRule("/(a)(\\d)/gi"), "$2-$1")).toBe("1-a 2-A");
    expect("xx".replace(compileRule("x"), "y")).toBe("yy");
    expect(() => compileRule("/[/g")).toThrow();
  });
  test("honors scope, role, ordering, enabled and turn-depth limits", () => {
    const rules = [rule(), rule({ id: "r2", findPattern: "丝巾", replaceWith: "爸爸", minDepth: 1, maxDepth: 2 })];
    expect(applyRules("你好{{user}}", rules, "frontend", "assistant", 1)).toBe("你好爸爸");
    expect(applyRules("{{user}}", rules, "frontend", "assistant", 0)).toBe("丝巾");
    expect(applyRules("{{user}}", rules, "context", "assistant")).toBe("{{user}}");
    expect(applyRules("{{user}}", rules, "frontend", "user")).toBe("{{user}}");
    expect(applyRules("{{user}}", [rule({ enabled: false })], "frontend", "assistant")).toBe("{{user}}");
  });
  test("counts paired turns and the last unanswered user exactly as desktop", () => {
    expect([...turnDepths([{ id: "u1", role: "user" }, { id: "a1", role: "assistant" }, { id: "u2", role: "user" }, { id: "a2", role: "assistant" }, { id: "u3", role: "user" }])]).toEqual([["u3", 0], ["a2", 1], ["u2", 1], ["a1", 2], ["u1", 2]]);
  });
  test("imports VChat and SillyTavern without reusing IDs", () => {
    const [v, st] = importRules([rule(), { scriptName: "ST", findRegex: "/x/gi", replaceString: "$1", placement: [1, 2], markdownOnly: false, promptOnly: true, disabled: true, minDepth: null, maxDepth: null }]);
    expect(v.id).not.toBe("r");
    expect(st).toMatchObject({ title: "ST", applyToRoles: ["user", "assistant"], applyToFrontend: false, applyToContext: true, enabled: false, minDepth: 0, maxDepth: -1 });
    expect(() => importRules([{ scriptName: "坏规则", findRegex: "/[/g" }])).toThrow("坏规则");
  });
  test("transforms outbound copies in global then Agent order, never saved originals", () => {
    const settings = { ...defaultSettings(), regexRules: [rule({ applyToContext: true })] };
    const agent: Agent = { id: "a", name: "助手", systemPrompt: "", model: "", temperature: null, createdAt: 1, regexRules: [rule({ findPattern: "丝巾", replaceWith: "爸爸", applyToContext: true })] };
    const messages: ChatMessage[] = [{ id: "m", topicId: "t", role: "assistant", content: "{{user}}", reasoning: "", attachments: [], status: "complete", createdAt: 1 }];
    expect(toApiMessages({ settings, agent, messages })[0].content).toBe("爸爸");
    expect(messages[0].content).toBe("{{user}}");
  });
});
