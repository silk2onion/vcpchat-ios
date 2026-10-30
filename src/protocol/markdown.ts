import createDOMPurify from "dompurify";
import { marked } from "marked";

marked.use({ gfm: true, breaks: true });

const MATH_PLACEHOLDER = /%%VCPMATH(\d+)%%/g;
const CODE_DOMAIN = /(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:\n\1[^\S\n]*(?=\n|$)|$)|`[^`\n]+`/g;

interface MathBlock {
  tex: string;
  display: boolean;
}

export function renderMarkdown(source: string): string {
  const { text, blocks } = protectMath(source);
  return restoreMath(sanitize(parseMarkdown(text), source), blocks);
}

/** Markdown for tool output and diary bodies: raw HTML outside code fences is shown as text. */
export function renderSafeMarkdown(source: string): string {
  const { text, blocks } = protectMath(escapeRawHtml(source));
  return restoreMath(sanitize(parseMarkdown(text), source), blocks);
}

export function parseMarkdown(source: string): string {
  const raw = marked.parse(source, { async: false });
  return typeof raw === "string" ? raw : "";
}

function sanitize(html: string, source: string): string {
  const windowLike = globalThis.window;
  if (!windowLike) return escapeHtml(source);
  const purify = createDOMPurify(windowLike);
  if (!purify.isSupported) return escapeHtml(source);
  const clean = stripActiveAttributes(
    purify.sanitize(html, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["style", "form", "input", "button", "iframe", "script"],
      FORBID_ATTR: ["style"],
    }),
  );
  return clean.replace(/<img\b(?![^>]*\bloading=)/gi, '<img loading="lazy" decoding="async"');
}

function stripActiveAttributes(html: string): string {
  return html
    .replace(/<\s*script\b[\s\S]*?>[\s\S]*?<\s*\/\s*script\s*>/gi, "")
    .replace(/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "");
}

export function escapeHtml(source: string): string {
  return source
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/** Applies `transform` to the parts of Markdown that are not fenced or inline code. */
export function mapOutsideCode(source: string, transform: (text: string) => string): string {
  let result = "";
  let cursor = 0;
  for (const match of source.matchAll(CODE_DOMAIN)) {
    result += transform(source.slice(cursor, match.index)) + match[0];
    cursor = match.index + match[0].length;
  }
  return result + transform(source.slice(cursor));
}

/** Blanks out fenced and inline code so offsets still line up with the source. */
export function maskCode(source: string): string {
  return source.replace(CODE_DOMAIN, (match) => match.replace(/[^\n]/g, " "));
}

function escapeRawHtml(source: string): string {
  return mapOutsideCode(source, (text) => text.replace(/</g, "&lt;"));
}

export function protectMath(source: string): { text: string; blocks: MathBlock[] } {
  const blocks: MathBlock[] = [];
  const hold = (tex: string, display: boolean) => {
    blocks.push({ tex: tex.trim(), display });
    return `%%VCPMATH${blocks.length - 1}%%`;
  };
  const text = mapOutsideCode(source, (part) =>
    protectInlineDollars(
      part
        .replace(/\$\$([\s\S]+?)\$\$/g, (_, tex: string) => hold(tex, true))
        .replace(/\\\[([\s\S]+?)\\\]/g, (_, tex: string) => hold(tex, true))
        .replace(/\\\(([\s\S]+?)\\\)/g, (_, tex: string) => hold(tex, false)),
      hold,
    ),
  );
  return { text, blocks };
}

function protectInlineDollars(text: string, hold: (tex: string, display: boolean) => string): string {
  return text.replace(/(^|[^\\$\w])\$([^\s$](?:[^$\n]*?[^\s$\\])?)\$(?![\w$])/g, (match, lead: string, tex: string) =>
    looksLikeMath(tex) ? lead + hold(tex, false) : match,
  );
}

function looksLikeMath(content: string): boolean {
  const tex = content.trim();
  if (!tex || tex.startsWith("/") || tex.includes("|")) return false;
  if (tex.startsWith("{") && tex.endsWith("}")) return false;
  const signal = /\\|[\^_=+\-*/<>]|[A-Za-z]\s*\(|\b(?:lim|sum|int|frac|sqrt|alpha|beta|gamma|theta|lambda|mu|sigma|pi|infty)\b/i.test(tex);
  const numeric = /^[+-]?(?:\d+(?:[.,]\d+)*|\.\d+)(?:\s*(?:%|\\%|°))?$/.test(tex);
  const identifier = /^[A-Za-z_][A-Za-z0-9_]*$/.test(tex);
  if (/^\d/.test(tex) && !signal && !numeric) return false;
  return signal || numeric || identifier;
}

function restoreMath(html: string, blocks: MathBlock[]): string {
  if (!blocks.length) return html;
  return html.replace(MATH_PLACEHOLDER, (placeholder, index: string) => {
    const block = blocks[Number(index)];
    if (!block) return placeholder;
    return `<span class="vcp-math" data-display="${block.display ? "block" : "inline"}">${escapeHtml(block.tex)}</span>`;
  });
}
