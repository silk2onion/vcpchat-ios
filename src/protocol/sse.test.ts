import { describe, expect, test } from "vitest";
import { createSseParser, extractSseJson } from "./sse";

describe("SSE", () => {
  test("reads content, reasoning, and array parts", () => {
    expect(extractSseJson({ choices: [{ delta: { content: "你" } }] }).content).toBe("你");
    expect(extractSseJson({ choices: [{ delta: { reasoning_content: "想" } }] }).reasoning).toBe("想");
    expect(
      extractSseJson({
        choices: [{ message: { content: [{ type: "text", text: "完整" }] } }],
      }).content,
    ).toBe("完整");
    expect(extractSseJson({ error: { message: "bad key" } }).error).toBe("bad key");
  });

  test("reassembles chunks split across TCP frames and stops on DONE", () => {
    const content: string[] = [];
    const reasoning: string[] = [];
    let done = 0;
    const parser = createSseParser({
      onContent: (text) => content.push(text),
      onReasoning: (text) => reasoning.push(text),
      onError: (message) => {
        throw new Error(message);
      },
      onDone: () => {
        done += 1;
      },
    });
    parser.push('data: {"choices":[{"delta":{"content":"你');
    parser.push('好"}}]}\n\n');
    parser.push("data: [DONE]\n\n");
    parser.finish();
    expect(content.join("")).toBe("你好");
    expect(reasoning).toEqual([]);
    expect(done).toBe(1);
  });

  test("ignores comments and malformed JSON without dropping the next event", () => {
    const content: string[] = [];
    const parser = createSseParser({
      onContent: (text) => content.push(text),
      onReasoning: () => {},
      onError: () => {},
      onDone: () => {},
    });
    parser.push(": keep-alive\n");
    parser.push("data: {not json}\n");
    parser.push('data: {"choices":[{"delta":{"reasoning":"先想","content":"后说"}}]}\n');
    parser.finish();
    expect(content).toEqual(["后说"]);
  });
});
