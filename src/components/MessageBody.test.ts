// @vitest-environment jsdom
import { createApp, h, nextTick, reactive } from "vue";
import { beforeEach, describe, expect, test, vi } from "vitest";

const loaders = vi.hoisted(() => ({ highlight: vi.fn(), katex: vi.fn(), mermaid: vi.fn() }));

vi.mock("../render/loaders", () => ({
  loadHighlighter: loaders.highlight,
  loadKatex: loaders.katex,
  prepareMermaid: loaders.mermaid,
}));

import { defaultSettings, type Settings } from "../domain";
import { optionsKey, renderOptionsFrom } from "../render/options";
import MessageBody from "./MessageBody.vue";

async function settle() {
  for (let i = 0; i < 5; i += 1) {
    await nextTick();
    await Promise.resolve();
  }
}

function mount(settings: Settings, content: string) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const app = createApp({
    render: () => {
      const options = renderOptionsFrom(settings);
      return h(MessageBody, { key: optionsKey(options), content, reasoning: "", options });
    },
  });
  app.mount(host);
  return { host, app };
}

describe("render settings", () => {
  beforeEach(() => {
    document.body.innerHTML = "";
    loaders.highlight.mockReset().mockResolvedValue({
      getLanguage: () => ({}),
      highlight: (code: string) => ({ value: `<span class="hljs-keyword">${code}</span>` }),
      highlightAuto: (code: string) => ({ value: code }),
    });
    loaders.katex.mockReset().mockResolvedValue({
      render: (tex: string, node: HTMLElement) => {
        node.innerHTML = `<span class="katex">${tex}</span>`;
      },
    });
  });

  test("turning rich rendering off re-renders as light Markdown", async () => {
    const settings = reactive(defaultSettings());
    const { host, app } = mount(settings, "```js\nlet x\n```\n\n$$a^2$$");
    await settle();
    expect(host.querySelector(".code-head")).not.toBeNull();
    expect(host.querySelector(".katex")).not.toBeNull();

    settings.richRender = false;
    await settle();
    expect(host.querySelector(".code-head")).toBeNull();
    expect(host.querySelector(".katex")).toBeNull();
    expect(host.querySelector(".vcp-math")?.textContent).toBe("a^2");

    settings.richRender = true;
    settings.renderMath = false;
    await settle();
    expect(host.querySelector(".code-head")).not.toBeNull();
    expect(host.querySelector(".katex")).toBeNull();
    app.unmount();
  });

  test("light mode never loads the heavy libraries", async () => {
    const settings = reactive({ ...defaultSettings(), richRender: false });
    const { app } = mount(settings, "```js\nlet x\n```\n\n$$a^2$$\n\n```mermaid\ngraph TD; A-->B\n```");
    await settle();
    expect(loaders.highlight).not.toHaveBeenCalled();
    expect(loaders.katex).not.toHaveBeenCalled();
    expect(loaders.mermaid).not.toHaveBeenCalled();
    app.unmount();
  });

  test("HTML bubbles only run in the sandbox when allowed", async () => {
    const settings = reactive(defaultSettings());
    const { host, app } = mount(settings, "<style>p{color:red}</style><p>红</p>");
    await settle();
    expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");

    settings.renderHtml = false;
    await settle();
    expect(host.querySelector("iframe")).toBeNull();
    expect(host.querySelector("style")).toBeNull();
    expect(host.textContent).toContain("红");
    app.unmount();
  });
});
