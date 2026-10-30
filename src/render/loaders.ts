import type { HLJSApi } from "highlight.js";
import type katexModule from "katex";
import type mermaidModule from "mermaid";

type Katex = typeof katexModule;
type Mermaid = typeof mermaidModule;

function memo<T>(load: () => Promise<T>): () => Promise<T> {
  let pending: Promise<T> | null = null;
  return () => {
    pending ??= load().catch((error: unknown) => {
      pending = null;
      throw error;
    });
    return pending;
  };
}

export const loadHighlighter = memo<HLJSApi>(async () => (await import("highlight.js/lib/common")).default);

export const loadKatex = memo<Katex>(async () => {
  const [katex] = await Promise.all([import("katex"), import("katex/dist/katex.min.css")]);
  return katex.default;
});

let mermaidTheme = "";

export const loadMermaid = memo<Mermaid>(async () => (await import("mermaid")).default);

export async function prepareMermaid(dark: boolean): Promise<Mermaid> {
  const mermaid = await loadMermaid();
  const theme = dark ? "dark" : "neutral";
  if (mermaidTheme !== theme) {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme, htmlLabels: false, fontFamily: "inherit" });
    mermaidTheme = theme;
  }
  return mermaid;
}
