import { describe, expect, test } from "vitest";
import type { Agent, ChatMessage, Settings } from "../domain";
import { defaultSettings } from "../domain";
import { attachmentKind, buildRequestBody, toApiMessages } from "./messages";

const agent: Agent = {
  id: "agent_1",
  name: "助手",
  systemPrompt: "简洁回答。",
  model: "",
  temperature: null,
  createdAt: 1,
};

function settings(partial: Partial<Settings> = {}): Settings {
  return { ...defaultSettings(), serverUrl: "http://127.0.0.1:6005", apiKey: "fixture-key", defaultModel: "demo", ...partial };
}

function message(partial: Partial<ChatMessage> & Pick<ChatMessage, "id" | "role" | "content">): ChatMessage {
  return {
    topicId: "topic_1",
    reasoning: "",
    attachments: [],
    createdAt: 1,
    status: "complete",
    ...partial,
  };
}

describe("chat payloads", () => {
  test("default settings do not contain a key", () => {
    const blank = defaultSettings();
    expect(blank.apiKey).toBe("");
    expect(blank.logKey).toBe("");
    expect(blank.adminPassword).toBe("");
  });

  test("omits temperature unless asked, and requires a model", () => {
    const body = JSON.parse(buildRequestBody(settings(), agent, [])) as { model: string; temperature?: number; stream: boolean };
    expect(body).toMatchObject({ model: "demo", stream: true });
    expect(body.temperature).toBeUndefined();
    const withTemperature = JSON.parse(buildRequestBody(settings({ sendTemperature: true, temperature: 0.2 }), agent, [])) as {
      temperature: number;
    };
    expect(withTemperature.temperature).toBe(0.2);
    expect(() => buildRequestBody(settings({ defaultModel: "" }), agent, [])).toThrow(/模型/);
  });

  test("sends images only on the latest user message and names group speakers", () => {
    const older = message({
      id: "u1",
      role: "user",
      content: "看这张",
      attachments: [{ id: "a", name: "old.png", mime: "image/png", kind: "image", dataUrl: "data:image/png;base64,old" }],
    });
    const latest = message({
      id: "u2",
      role: "user",
      content: "再看",
      attachments: [
        { id: "b", name: "new.png", mime: "image/png", kind: "image", dataUrl: "data:image/png;base64,new" },
        { id: "c", name: "note.txt", mime: "text/plain", kind: "text", text: "hello" },
      ],
    });
    const reply = message({ id: "a1", role: "assistant", content: "收到", authorName: "助手" });
    const api = toApiMessages({
      settings: settings({ userName: "林" }),
      agent,
      group: { id: "g", name: "圆桌", memberIds: ["agent_1"], mode: "rotate", createdAt: 1 },
      messages: [older, reply, latest],
    });
    expect(api[0].content).toContain("林");
    expect(api[0].content).toContain("圆桌");
    expect(api[1].content).toBe("看这张");
    expect(api[2].content).toBe("【助手】\n收到");
    expect(Array.isArray(api[3].content)).toBe(true);
    const parts = api[3].content as { type: string; text?: string; image_url?: { url: string } }[];
    expect(parts.some((part) => part.image_url?.url.includes("new"))).toBe(true);
    expect(parts.some((part) => part.text?.includes("hello"))).toBe(true);
    expect(JSON.stringify(api)).not.toContain("base64,old");
  });

  test("rejects svg and oversized files before they are read", () => {
    expect(attachmentKind({ name: "a.png", type: "image/png", size: 100 })).toBe("image");
    expect(attachmentKind({ name: "a.md", type: "", size: 20 })).toBe("text");
    expect(() => attachmentKind({ name: "a.svg", type: "image/svg+xml", size: 10 })).toThrow(/SVG/);
    expect(() => attachmentKind({ name: "a.png", type: "image/png", size: 2_000_000 })).toThrow(/1\.5MB/);
  });
});

test("synced group unified model and group prompt apply to replies without changing one-to-one defaults",()=>{
 const group={id:"sync:g",name:"桌面群",memberIds:[agent.id],mode:"all" as const,createdAt:1,unifiedModel:"shared-model",systemPrompt:"协同讨论"};
 expect(JSON.parse(buildRequestBody(settings(),agent,[],group)).model).toBe("shared-model");expect(JSON.parse(buildRequestBody(settings(),agent,[])).model).toBe("demo");expect(toApiMessages({settings:settings(),agent,group,messages:[]})[0].content).toContain("协同讨论");
});
