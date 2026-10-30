// @vitest-environment jsdom
import { beforeEach, describe, expect, test, vi } from "vitest";

const loaders = vi.hoisted(() => ({
  highlight: vi.fn(),
  katex: vi.fn(),
  mermaid: vi.fn(),
}));

vi.mock("./loaders", () => ({
  loadHighlighter: loaders.highlight,
  loadKatex: loaders.katex,
  prepareMermaid: loaders.mermaid,
}));

import { renderMarkdown } from "../protocol/markdown";
import { enhance } from "./enhance";
import { isVideoUrl, viewerItem } from "./media";
import { fullRenderOptions, lightRenderOptions, optionsKey } from "./options";

function mount(markdown: string): HTMLElement {
  const root = document.createElement("div");
  root.innerHTML = renderMarkdown(markdown);
  document.body.appendChild(root);
  return root;
}

describe("message enhancement", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    viewerItem.value = null;
    loaders.highlight.mockReset().mockResolvedValue({
      getLanguage: (name: string) => (name === "js" ? {} : undefined),
      highlight: (code: string) => ({ value: `<span class="hljs-keyword">${code}</span>` }),
      highlightAuto: (code: string) => ({ value: code }),
    });
    loaders.katex.mockReset().mockResolvedValue({
      render: (tex: string, node: HTMLElement) => {
        node.innerHTML = `<span class="katex">${tex}</span>`;
      },
    });
    loaders.mermaid.mockReset();
  });

  test("plain prose loads no heavy library", async () => {
    await enhance(mount("只是一段话。"), fullRenderOptions());
    expect(loaders.highlight).not.toHaveBeenCalled();
    expect(loaders.katex).not.toHaveBeenCalled();
    expect(loaders.mermaid).not.toHaveBeenCalled();
  });

  test("code gets a copy button and highlighting", async () => {
    const root = mount("```js\nconst a = 1\n```");
    await enhance(root, fullRenderOptions());
    expect(root.querySelector(".code-head")?.textContent).toContain("复制");
    expect(root.querySelector("code.hljs .hljs-keyword")).not.toBeNull();
    expect(loaders.katex).not.toHaveBeenCalled();
  });

  test("formulas load KaTeX only when present", async () => {
    const root = mount("$$x^2$$");
    await enhance(root, fullRenderOptions());
    expect(loaders.katex).toHaveBeenCalledTimes(1);
    expect(root.querySelector(".katex")?.textContent).toBe("x^2");
  });

  test("html fences offer a sandbox preview", async () => {
    const root = mount("```html\n<p>hi</p>\n```");
    await enhance(root, fullRenderOptions());
    const preview = [...root.querySelectorAll("button")].find((button) => button.textContent === "预览");
    preview?.click();
    const frame = root.querySelector("iframe");
    expect(frame?.getAttribute("sandbox")).toBe("allow-scripts");
  });

  test("video links become players and images open the viewer", async () => {
    const root = mount("[片段](https://example.test/a.mp4)\n\n![图](https://example.test/b.png)");
    await enhance(root, fullRenderOptions());
    expect(root.querySelector("video")?.getAttribute("src")).toBe("https://example.test/a.mp4");
    root.querySelector("img")?.dispatchEvent(new Event("click"));
    expect(viewerItem.value).toMatchObject({ kind: "image", src: "https://example.test/b.png" });
  });

  test("light mode leaves the sanitized Markdown untouched", async () => {
    const root = mount("```js\nx\n```\n\n$$y$$");
    const before = root.innerHTML;
    await enhance(root, lightRenderOptions());
    expect(root.innerHTML).toBe(before);
    expect(loaders.highlight).not.toHaveBeenCalled();
  });

  test("options key changes when any switch changes", () => {
    const full = fullRenderOptions();
    expect(optionsKey({ ...full, math: false })).not.toBe(optionsKey(full));
    expect(optionsKey({ ...full, rich: false })).toBe(optionsKey(lightRenderOptions()));
  });

  test("recognizes video URLs", () => {
    expect(isVideoUrl("https://cdn.test/v/clip.webm?x=1")).toBe(true);
    expect(isVideoUrl("javascript:alert(1)//.mp4")).toBe(false);
    expect(isVideoUrl("https://cdn.test/a.png")).toBe(false);
  });
});
