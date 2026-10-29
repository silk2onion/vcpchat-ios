import createDOMPurify from "dompurify";
import { marked } from "marked";

marked.use({ gfm: true, breaks: true });

export function renderMarkdown(source: string): string {
  const raw = marked.parse(source, { async: false });
  const html = typeof raw === "string" ? raw : "";
  const windowLike = globalThis.window;
  if (!windowLike) return escapeHtml(source);
  const purify = createDOMPurify(windowLike);
  if (!purify.isSupported) return escapeHtml(source);
  return stripActiveAttributes(
    purify.sanitize(html, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["style", "form", "input", "button", "iframe", "script"],
      FORBID_ATTR: ["style"],
    }),
  );
}

function stripActiveAttributes(html: string): string {
  return html
    .replace(/<\s*script\b[\s\S]*?>[\s\S]*?<\s*\/\s*script\s*>/gi, "")
    .replace(/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "");
}

function escapeHtml(source: string): string {
  return source
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}
