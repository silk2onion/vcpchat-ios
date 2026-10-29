import { describe, expect, test } from "vitest";
import { parseSegments } from "./tools";

const request = `先说一句。
<<<[TOOL_REQUEST]>>>
tool_name:「始」DailyNote「末」,
command:「始」update「末」
<<<[END_TOOL_REQUEST]>>>
再说一句。`;

describe("tool blocks", () => {
  test("splits prose and a closed tool request", () => {
    const segments = parseSegments(request);
    expect(segments.map((segment) => segment.type)).toEqual(["text", "tool", "text"]);
    const tool = segments[1];
    expect(tool).toMatchObject({ type: "tool", name: "DailyNote", command: "update", closed: true });
  });

  test("keeps an unfinished tool open while streaming", () => {
    const segments = parseSegments('<<<[TOOL_REQUEST]>>>\ntool_name:「始」Weather「末」');
    expect(segments[0]).toMatchObject({ type: "tool", name: "Weather", closed: false });
  });

  test("does not treat fenced or backticked markers as protocol", () => {
    const source = "代码里写着 `<<<[TOOL_REQUEST]>>>`。\n```\n<<<[TOOL_REQUEST]>>>\ntool_name:「始」Nope「末」\n<<<[END_TOOL_REQUEST]>>>\n```\n正文";
    const segments = parseSegments(source);
    expect(segments.every((segment) => segment.type === "text")).toBe(true);
  });

  test("nests tool-result markers and keeps think blocks", () => {
    const source = `<think>内部</think>\n[[VCP调用结果信息汇总: 外层 [[VCP调用结果信息汇总: 内层 VCP调用结果结束]] 仍在外层 VCP调用结果结束]]之后`;
    const segments = parseSegments(source);
    expect(segments[0]).toMatchObject({ type: "think", text: "内部", closed: true });
    expect(segments[1]).toMatchObject({ type: "result", closed: true });
    expect(segments[1].type === "result" && segments[1].text.includes("仍在外层")).toBe(true);
    expect(segments.at(-1)).toMatchObject({ type: "text", text: "之后" });
  });

  test("accepts a short or long end marker", () => {
    const segments = parseSegments("<<<[TOOL_REQUEST]>>>tool_name: Echo<<[END_TOOL_REQUEST]>>尾");
    expect(segments[0]).toMatchObject({ type: "tool", name: "Echo", closed: true });
  });
});
