import { loadHighlighter, loadKatex, prepareMermaid } from "./loaders";
import { isSafeMediaUrl, isVideoUrl, openViewer } from "./media";
import type { RenderOptions } from "./options";
import { mountSandbox } from "./sandbox";

const MERMAID_LANGS = new Set(["mermaid", "flowchart", "graph"]);
const HTML_LANGS = new Set(["html", "htm", "xhtml"]);
const AUTO_DETECT_LIMIT = 4000;
const HIGHLIGHT_LIMIT = 60_000;

export async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    area.remove();
    return copied;
  }
}

function button(label: string, onClick: (target: HTMLButtonElement) => void): HTMLButtonElement {
  const element = document.createElement("button");
  element.type = "button";
  element.className = "code-action";
  element.textContent = label;
  element.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    onClick(element);
  });
  return element;
}

function languageOf(code: Element): string {
  return code.className.match(/language-([\w+#.-]+)/)?.[1]?.toLowerCase() ?? "";
}

function isDark(): boolean {
  return getComputedStyle(document.documentElement).colorScheme.includes("dark");
}

let mermaidQueue: Promise<unknown> = Promise.resolve();
let mermaidCounter = 0;

function renderMermaid(host: HTMLElement, source: string) {
  const job = mermaidQueue.then(async () => {
    if (!host.isConnected) return;
    try {
      const mermaid = await prepareMermaid(isDark());
      mermaidCounter += 1;
      const { svg } = await mermaid.render(`vcp-mermaid-${mermaidCounter}`, source);
      if (!host.isConnected) return;
      const view = document.createElement("div");
      view.className = "mermaid-view";
      view.innerHTML = svg;
      host.replaceChildren(view);
    } catch (error) {
      const note = document.createElement("p");
      note.className = "render-error";
      note.textContent = `图表没有画出来：${error instanceof Error ? error.message.split("\n")[0] : "语法错误"}`;
      host.prepend(note);
    }
  });
  mermaidQueue = job.catch(() => undefined);
}

function enhanceCode(root: HTMLElement, options: RenderOptions, cleanups: (() => void)[]): Promise<void>[] {
  const pending: Promise<void>[] = [];
  for (const code of root.querySelectorAll<HTMLElement>("pre > code")) {
    const pre = code.parentElement as HTMLPreElement;
    if (pre.dataset.enhanced) continue;
    pre.dataset.enhanced = "1";
    const lang = languageOf(code);
    const source = code.textContent ?? "";
    if (options.mermaid && MERMAID_LANGS.has(lang)) {
      const host = document.createElement("div");
      host.className = "mermaid-block";
      pre.replaceWith(host);
      host.appendChild(pre);
      const needsKeyword = lang !== "mermaid" && !source.trimStart().toLowerCase().startsWith(lang);
      renderMermaid(host, needsKeyword ? `${lang} ${source}` : source);
      continue;
    }
    const block = document.createElement("div");
    block.className = "code-block";
    const head = document.createElement("div");
    head.className = "code-head";
    const label = document.createElement("span");
    label.textContent = lang || "text";
    head.appendChild(label);
    const actions = document.createElement("span");
    actions.className = "code-actions";
    head.appendChild(actions);
    pre.before(block);
    block.append(head, pre);
    if (options.html && HTML_LANGS.has(lang)) {
      let destroy: (() => void) | null = null;
      const preview = document.createElement("div");
      preview.className = "sandbox-host";
      block.appendChild(preview);
      actions.appendChild(
        button("预览", (target) => {
          if (destroy) {
            destroy();
            destroy = null;
            block.classList.remove("previewing");
            target.textContent = "预览";
            return;
          }
          destroy = mountSandbox(preview, source);
          block.classList.add("previewing");
          target.textContent = "代码";
        }),
      );
      cleanups.push(() => destroy?.());
    }
    actions.appendChild(
      button("复制", (target) => {
        void copyText(source).then((copied) => {
          target.textContent = copied ? "已复制" : "复制失败";
          window.setTimeout(() => {
            target.textContent = "复制";
          }, 1400);
        });
      }),
    );
    if (options.code && source.length <= HIGHLIGHT_LIMIT && (lang || source.length <= AUTO_DETECT_LIMIT)) {
      pending.push(
        loadHighlighter()
          .then((hljs) => {
            if (!code.isConnected) return;
            const known = lang && hljs.getLanguage(lang);
            if (lang && !known) return;
            const result = known ? hljs.highlight(source, { language: lang, ignoreIllegals: true }) : hljs.highlightAuto(source);
            code.innerHTML = result.value;
            code.classList.add("hljs");
          })
          .catch(() => undefined),
      );
    }
  }
  return pending;
}

function enhanceMath(root: HTMLElement): Promise<void> | null {
  const nodes = [...root.querySelectorAll<HTMLElement>(".vcp-math:not([data-rendered])")];
  if (!nodes.length) return null;
  return loadKatex()
    .then((katex) => {
      for (const node of nodes) {
        const tex = node.textContent ?? "";
        node.dataset.rendered = "1";
        katex.render(tex, node, {
          displayMode: node.dataset.display === "block",
          throwOnError: false,
          strict: "ignore",
          trust: false,
          maxExpand: 1000,
          maxSize: 20,
        });
      }
    })
    .catch(() => undefined);
}

function video(src: string): HTMLVideoElement {
  const element = document.createElement("video");
  element.src = src;
  element.controls = true;
  element.playsInline = true;
  element.preload = "metadata";
  element.className = "media-video";
  return element;
}

function enhanceMedia(root: HTMLElement) {
  for (const img of root.querySelectorAll<HTMLImageElement>("img:not([data-enhanced])")) {
    img.dataset.enhanced = "1";
    const src = img.getAttribute("src") ?? "";
    if (isVideoUrl(src)) {
      img.replaceWith(video(src));
      continue;
    }
    if (!isSafeMediaUrl(src)) continue;
    img.classList.add("media-thumb");
    img.addEventListener("click", (event) => {
      event.preventDefault();
      openViewer({ kind: "image", src, alt: img.alt });
    });
  }
  for (const link of root.querySelectorAll<HTMLAnchorElement>("a[href]:not([data-enhanced])")) {
    link.dataset.enhanced = "1";
    const href = link.getAttribute("href") ?? "";
    if (!isVideoUrl(href)) continue;
    const figure = document.createElement("figure");
    figure.className = "media-figure";
    figure.appendChild(video(href));
    const caption = link.textContent?.trim();
    if (caption && caption !== href) {
      const text = document.createElement("figcaption");
      text.textContent = caption;
      figure.appendChild(text);
    }
    link.replaceWith(figure);
  }
  for (const element of root.querySelectorAll<HTMLVideoElement>("video:not(.media-video)")) {
    element.controls = true;
    element.playsInline = true;
    element.preload = "metadata";
    element.classList.add("media-video");
  }
}

/** Upgrades sanitized Markdown in place. Returns a function that releases sandboxes it created. */
export async function enhance(root: HTMLElement, options: RenderOptions): Promise<() => void> {
  const cleanups: (() => void)[] = [];
  if (!options.rich) return () => undefined;
  if (options.media) enhanceMedia(root);
  const pending = enhanceCode(root, options, cleanups);
  if (options.math) {
    const math = enhanceMath(root);
    if (math) pending.push(math);
  }
  await Promise.all(pending);
  return () => {
    for (const cleanup of cleanups) cleanup();
  };
}
