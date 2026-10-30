import { describe, expect, test } from "vitest";
import { parseResultFields, parseSegments } from "./tools";

const request = `先说一句。
<<<[TOOL_REQUEST]>>>
tool_name:「始」FileOperator「末」,
command:「始」update「末」
<<<[END_TOOL_REQUEST]>>>
再说一句。`;

describe("tool blocks", () => {
  test("splits prose and a closed tool request", () => {
    const segments = parseSegments(request);
    expect(segments.map((segment) => segment.type)).toEqual(["text", "tool", "text"]);
    const tool = segments[1];
    expect(tool).toMatchObject({ type: "tool", name: "FileOperator", command: "update", closed: true });
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

  test("renders a DailyNote create request as a diary card", () => {
    const source = `<<<[TOOL_REQUEST]>>>
tool_name:「始」DailyNote「末」,
command:「始」create「末」,
maid:「始」小克「末」,
Date:「始」2026.10.29「末」,
folder:「始」日常「末」,
Content:「始」今天**很好**。「末」,
Tag:「始」日常, 晴「末」
<<<[END_TOOL_REQUEST]>>>`;
    const [segment] = parseSegments(source);
    expect(segment).toMatchObject({
      type: "diary",
      closed: true,
      entry: { mode: "create", agent: "小克", agentLabel: "Maid", date: "2026.10.29", folder: "日常", content: "今天**很好**。", tag: "日常, 晴" },
    });
  });

  test("renders a DailyNote update as before and after, even mid-stream", () => {
    const source = "<<<[TOOL_REQUEST]>>>\ntool_name:「始」DailyNote「末」,\nvalet:「始」阿德「末」,\ntarget:「始」旧句子「末」,\nreplace:「始」新句";
    const [segment] = parseSegments(source);
    expect(segment).toMatchObject({ type: "diary", closed: false, entry: { mode: "update", agent: "阿德", agentLabel: "Valet", target: "旧句子", replace: "新句" } });
  });

  test("reads the legacy DailyNote block", () => {
    const [segment] = parseSegments("<<<DailyNoteStart>>>\nMaid: 小克\nDate: 2026-10-29\nContent: 写了一行\n<<<DailyNoteEnd>>>");
    expect(segment).toMatchObject({ type: "diary", closed: true, entry: { agent: "小克", date: "2026-10-29", content: "写了一行" } });
  });

  test("pulls name, status and body out of a tool result", () => {
    const parsed = parseResultFields("- 工具名称: SciCalculator\n- 执行状态: ✅ SUCCESS\n- 返回内容: 第一行\n第二行");
    expect(parsed).toMatchObject({ toolName: "SciCalculator", status: "✅ SUCCESS", ok: true, content: "第一行\n第二行", fields: [] });
    expect(parseResultFields("- 工具名称: X\n- 执行状态: ❌ ERROR").ok).toBe(false);
  });

  test("recognizes role dividers, thought chains, summaries and desktop pushes", () => {
    const source = [
      "<<<[ROLE_DIVIDE_USER]>>>",
      '[--- VCP元思考链: "反思" ---]',
      "想法",
      "[--- 元思考链结束 ---]",
      "[本轮工具调用摘要:]",
      "- 搜索",
      "- 画图",
      "[本轮工具调用摘要结束]",
      "<<<[DESKTOP_PUSH]>>>挂件<<<[DESKTOP_PUSH_END]>>>",
      "<<<[END_ROLE_DIVIDE_USER]>>>",
    ].join("\n");
    const segments = parseSegments(source);
    expect(segments.map((segment) => segment.type)).toEqual(["divider", "think", "summary", "push", "divider"]);
    expect(segments[1]).toMatchObject({ title: "反思", text: "想法", closed: true });
    expect(segments[2]).toMatchObject({ items: ["搜索", "画图"] });
    expect(segments[4]).toMatchObject({ role: "user", end: true });
  });

  test("keeps a malformed divider as text", () => {
    expect(parseSegments("<<<[ROLE_DIVIDE_ROBOT]>>> 你好")).toEqual([{ type: "text", text: "<<<[ROLE_DIVIDE_ROBOT]>>> 你好" }]);
  });
});
