// @vitest-environment happy-dom
import { describe, expect, test } from "vitest";
import { renderMarkdown } from "./markdown";

describe("markdown", () => {
  test("renders formatting and strips active markup", () => {
    const html = renderMarkdown("**粗**\n\n<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>");
    expect(html).toContain("<strong>粗</strong>");
    expect(html.toLowerCase()).not.toContain("<script");
    expect(html.toLowerCase()).not.toContain("onerror");
  });
});
