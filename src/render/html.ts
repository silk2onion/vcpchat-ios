import { maskCode } from "../protocol/markdown";

export type Island = { type: "markdown"; text: string } | { type: "html"; html: string; closed: boolean; document: boolean };

const DOCUMENT_START = /<!doctype\s+html\b|<html[\s>]/i;
const DOCUMENT_END = /<\/html\s*>/i;
const ACTIVE_HTML = /<(?:style|script|canvas)\b|<svg[\s>]/i;

/**
 * Splits assistant text into Markdown and HTML that should run in a sandbox, the way the desktop
 * client lets a reply carry its own page: whole documents become their own island, and a text run
 * with `<style>`, `<script>`, `<canvas>` or `<svg>` outside code is rendered as one HTML bubble.
 */
export function splitHtmlIslands(text: string, streaming: boolean): Island[] {
  const masked = maskCode(text);
  const islands: Island[] = [];
  let cursor = 0;
  while (cursor < text.length) {
    const rest = masked.slice(cursor);
    const start = rest.search(DOCUMENT_START);
    if (start < 0) break;
    const from = cursor + start;
    const endMatch = DOCUMENT_END.exec(masked.slice(from));
    if (from > cursor) islands.push({ type: "markdown", text: text.slice(cursor, from) });
    if (!endMatch) {
      islands.push({ type: "html", html: text.slice(from), closed: !streaming, document: true });
      cursor = text.length;
      break;
    }
    const to = from + endMatch.index + endMatch[0].length;
    islands.push({ type: "html", html: text.slice(from, to), closed: true, document: true });
    cursor = to;
  }
  if (cursor < text.length) islands.push({ type: "markdown", text: text.slice(cursor) });
  return islands
    .map((island): Island => {
      if (island.type !== "markdown" || !ACTIVE_HTML.test(maskCode(island.text))) return island;
      return { type: "html", html: island.text, closed: !streaming, document: false };
    })
    .filter((island) => island.type === "html" || island.text.trim().length > 0);
}
