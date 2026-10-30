// @vitest-environment jsdom
import { describe, expect, test } from "vitest";
import { protectMath, renderMarkdown, renderSafeMarkdown } from "./markdown";

describe("markdown", () => {
  test("renders formatting and strips active markup", () => {
    const html = renderMarkdown("**粗**\n\n<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>");
    expect(html).toContain("<strong>粗</strong>");
    expect(html.toLowerCase()).not.toContain("<script");
    expect(html.toLowerCase()).not.toContain("onerror");
  });

  test("keeps TeX away from emphasis and marks it for KaTeX", () => {
    const html = renderMarkdown("面积 $a_1 * b_2$，以及\n\n$$\\int_0^1 x^2 dx$$");
    expect(html).toContain('<span class="vcp-math" data-display="inline">a_1 * b_2</span>');
    expect(html).toContain('data-display="block">\\int_0^1 x^2 dx</span>');
    expect(html).not.toContain("<em>");
  });

  test("leaves prices and code alone", () => {
    const { blocks } = protectMath("花了 $5 和 $10 块。`$x$` 不算\n```\n$$y$$\n```");
    expect(blocks).toEqual([]);
  });

  test("accepts \\( \\) and \\[ \\] delimiters", () => {
    const { blocks } = protectMath("行内 \\(x^2\\) 和块 \\[y = mx + b\\]");
    expect(blocks).toEqual([
      { tex: "y = mx + b", display: true },
      { tex: "x^2", display: false },
    ]);
  });

  test("adds lazy loading to images", () => {
    expect(renderMarkdown("![猫](https://example.test/cat.png)")).toContain('loading="lazy"');
  });

  test("shows raw HTML in tool output as text", () => {
    const html = renderSafeMarkdown("<b>粗</b>\n\n```html\n<i>x</i>\n```");
    expect(html).toContain("&lt;b&gt;粗");
    expect(html).not.toContain("<b>");
    expect(html).toContain("&lt;i&gt;x&lt;/i&gt;");
  });
});
