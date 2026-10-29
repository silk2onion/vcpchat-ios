import { describe, expect, test } from "vitest";
import { redactSecrets } from "./redact";
import { summarizePayload } from "./logs";

describe("redaction and log summaries", () => {
  test("removes secrets without touching shorter lookalikes", () => {
    expect(redactSecrets("ws://host/VCPlog/VCP_Key=fixture-key", ["fixture-key"])).toBe("ws://host/VCPlog/VCP_Key=••••");
    expect(redactSecrets("key", ["key"])).toBe("key");
  });

  test("summarizes a VCPLog payload", () => {
    const summary = summarizePayload({ type: "tool_call", message: "DailyNote", nested: { ok: true } });
    expect(summary.title).toBe("tool_call");
    expect(summary.detail).toContain("DailyNote");
  });
});
