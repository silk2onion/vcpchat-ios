import { describe, expect, test } from "vitest";
import { splitHtmlIslands } from "./html";
import { buildSandboxDocument, clampHeight, SANDBOX_CSP } from "./sandbox";

describe("html islands", () => {
  test("lifts a whole document out of the surrounding prose", () => {
    const islands = splitHtmlIslands("看这个：\n<!DOCTYPE html><html><body><p>嗨</p></body></html>\n喜欢吗", false);
    expect(islands.map((island) => island.type)).toEqual(["markdown", "html", "markdown"]);
    expect(islands[1]).toMatchObject({ document: true, closed: true });
  });

  test("waits for an unfinished document while streaming", () => {
    const [island] = splitHtmlIslands("<html><body><div>", true);
    expect(island).toMatchObject({ type: "html", closed: false });
  });

  test("treats prose with style or script as one bubble", () => {
    const [island] = splitHtmlIslands("<style>.a{animation:spin 1s}</style>\n<div class=a>转</div>", false);
    expect(island).toMatchObject({ type: "html", document: false, closed: true });
  });

  test("ignores HTML inside code", () => {
    const islands = splitHtmlIslands("```html\n<html><style></style></html>\n```\n以及 `<script>`", false);
    expect(islands).toEqual([{ type: "markdown", text: "```html\n<html><style></style></html>\n```\n以及 `<script>`" }]);
  });
});

describe("sandbox document", () => {
  const theme = { background: "#111", color: "#eee" };

  test("wraps a fragment with the CSP and a resize reporter", () => {
    const doc = buildSandboxDocument("<b>x</b>", "frame-1", theme);
    expect(doc).toContain(`content="${SANDBOX_CSP}"`);
    expect(doc).toContain("connect-src 'none'");
    expect(doc).toContain('"frame-1"');
    expect(doc).toContain("<b>x</b>");
  });

  test("injects into an existing document head and body", () => {
    const doc = buildSandboxDocument("<!doctype html><html><head><title>t</title></head><body>b</body></html>", "f", theme);
    expect(doc.indexOf("Content-Security-Policy")).toBeLessThan(doc.indexOf("<title>"));
    expect(doc.indexOf("vcp-html-resize")).toBeLessThan(doc.indexOf("</body>"));
  });

  test("bounds the reported height", () => {
    expect(clampHeight(10)).toBe(60);
    expect(clampHeight(999_999)).toBe(2400);
    expect(clampHeight("100")).toBeNull();
  });
});
