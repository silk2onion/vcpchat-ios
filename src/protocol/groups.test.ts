import { describe, expect, test } from "vitest";
import type { Agent, Group } from "../domain";
import { nextDelay, selectSpeakers } from "./groups";

const agents: Agent[] = [
  { id: "a", name: "林", systemPrompt: "", model: "", temperature: null, createdAt: 1 },
  { id: "b", name: "林深", systemPrompt: "", model: "", temperature: null, createdAt: 1 },
  { id: "c", name: "舟", systemPrompt: "", model: "", temperature: null, createdAt: 1 },
];

function group(mode: Group["mode"]): Group {
  return { id: "g", name: "圆桌", memberIds: ["a", "b", "c"], mode, createdAt: 1 };
}

describe("groups", () => {
  test("rotates, mentions the longer name first, and can ask everyone", () => {
    expect(selectSpeakers(group("rotate"), agents, "继续", 1).map((agent) => agent.id)).toEqual(["b"]);
    expect(selectSpeakers(group("mention"), agents, "请 @林深 看一下", 0).map((agent) => agent.id)).toEqual(["b"]);
    expect(selectSpeakers(group("all"), agents, "都说说", 0)).toHaveLength(3);
    expect(selectSpeakers(group("mention"), agents, "没有点名", 2).map((agent) => agent.id)).toEqual(["c"]);
  });

  test("backs off socket retries up to 30 seconds", () => {
    expect(nextDelay(1000)).toBe(2000);
    expect(nextDelay(20_000)).toBe(30_000);
  });
});
