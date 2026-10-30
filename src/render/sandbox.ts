const MIN_HEIGHT = 60;
const MAX_HEIGHT = 2400;

/**
 * The frame runs with `sandbox="allow-scripts"` and no `allow-same-origin`, so it gets an opaque origin:
 * no access to the app DOM, IndexedDB, cookies or the Tauri bridge. The CSP additionally blocks
 * fetch/XHR/WebSocket, nested frames and form posts; scripts and styles may come inline or from https CDNs.
 */
export const SANDBOX_CSP = [
  "default-src 'none'",
  "script-src 'unsafe-inline' 'unsafe-eval' https:",
  "style-src 'unsafe-inline' https:",
  "img-src data: blob: https: http:",
  "media-src data: blob: https: http:",
  "font-src data: https:",
  "connect-src 'none'",
  "frame-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
].join("; ");

export interface SandboxTheme {
  background: string;
  color: string;
}

function resizeScript(frameId: string): string {
  return `<script>(function(){var id=${JSON.stringify(frameId)};function send(){var h=Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0);parent.postMessage({type:"vcp-html-resize",frameId:id,height:h},"*");}addEventListener("load",function(){send();setTimeout(send,300);setTimeout(send,1200);});if(window.ResizeObserver)new ResizeObserver(send).observe(document.documentElement);send();})();</script>`;
}

export function isFullDocument(html: string): boolean {
  return /^\s*(?:<!--[\s\S]*?-->\s*)*(?:<!doctype\s+html\b|<html[\s>])/i.test(html);
}

export function buildSandboxDocument(html: string, frameId: string, theme: SandboxTheme): string {
  const head = `<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${SANDBOX_CSP}"><meta name="viewport" content="width=device-width,initial-scale=1">`;
  const base = `<style>html,body{margin:0;background:${theme.background};color:${theme.color};font-family:-apple-system,"PingFang SC",sans-serif;line-height:1.5;overflow-x:auto}body{padding:12px}*{box-sizing:border-box}img,video,canvas,svg{max-width:100%;height:auto}</style>`;
  const script = resizeScript(frameId);
  if (isFullDocument(html)) {
    let doc = html;
    doc = /<head[^>]*>/i.test(doc) ? doc.replace(/<head[^>]*>/i, (match) => `${match}${head}`) : doc.replace(/<html[^>]*>/i, (match) => `${match}<head>${head}</head>`);
    return /<\/body>/i.test(doc) ? doc.replace(/<\/body>/i, `${script}</body>`) : `${doc}${script}`;
  }
  return `<!doctype html><html><head>${head}${base}</head><body>${html}${script}</body></html>`;
}

export function clampHeight(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, Math.ceil(value)));
}

const frames = new Map<string, HTMLIFrameElement>();
let listening = false;

function onMessage(event: MessageEvent) {
  const data = event.data as { type?: unknown; frameId?: unknown; height?: unknown } | null;
  if (!data || data.type !== "vcp-html-resize" || typeof data.frameId !== "string") return;
  const frame = frames.get(data.frameId);
  if (!frame || event.source !== frame.contentWindow) return;
  const height = clampHeight(data.height);
  if (height !== null) frame.style.height = `${height}px`;
}

let counter = 0;

export function currentSandboxTheme(): SandboxTheme {
  if (typeof document === "undefined") return { background: "#ffffff", color: "#111111" };
  const style = getComputedStyle(document.documentElement);
  return {
    background: style.getPropertyValue("--bg-raise").trim() || "#ffffff",
    color: style.getPropertyValue("--ink").trim() || "#111111",
  };
}

/** Mounts a sandboxed frame into `host` and returns a function that tears it down. */
export function mountSandbox(host: HTMLElement, html: string): () => void {
  if (!listening) {
    window.addEventListener("message", onMessage);
    listening = true;
  }
  counter += 1;
  const frameId = `vcp-frame-${Date.now().toString(36)}-${counter}`;
  const frame = document.createElement("iframe");
  frame.className = "sandbox-frame";
  frame.setAttribute("sandbox", "allow-scripts");
  frame.setAttribute("referrerpolicy", "no-referrer");
  frame.setAttribute("loading", "lazy");
  frame.title = "HTML 气泡";
  frame.style.height = "160px";
  frame.srcdoc = buildSandboxDocument(html, frameId, currentSandboxTheme());
  frames.set(frameId, frame);
  host.appendChild(frame);
  return () => {
    frames.delete(frameId);
    frame.srcdoc = "";
    frame.remove();
  };
}
