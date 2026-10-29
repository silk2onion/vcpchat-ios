import type { EndpointMode } from "../domain";

const CHAT_SUFFIX = "/v1/chat/completions";
const TOOLS_SUFFIX = "/v1/chatvcp/completions";
const MODELS_SUFFIX = "/v1/models";

function hasControl(value: string): boolean {
  for (const char of value) {
    if (char.charCodeAt(0) <= 31) return true;
  }
  return false;
}

export class EndpointError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EndpointError";
  }
}

export function ensureHttpScheme(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) throw new EndpointError("服务器地址不能为空");
  if (hasControl(trimmed)) throw new EndpointError("URL 不能包含控制字符");
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed)) return trimmed;
  return `http://${trimmed}`;
}

function explicitDefaultPort(raw: string): string | null {
  const match = raw.match(/^[a-z][a-z0-9+.-]*:\/\/(?:[^/?#@]*@)?(\[[^\]]+\]|[^/:?#]+):(\d+)/i);
  if (!match) return null;
  const port = match[2];
  const scheme = raw.slice(0, raw.indexOf(":")).toLowerCase();
  const implicit = scheme === "https" ? "443" : scheme === "http" ? "80" : scheme === "wss" ? "443" : scheme === "ws" ? "80" : "";
  return port === implicit ? port : null;
}

function reinstatePort(serialized: string, port: string | null): string {
  if (!port) return serialized;
  return serialized.replace(/^([a-z][a-z0-9+.-]*:\/\/\[?[^\s/?#\]]+\]?)/i, (host) => (host.endsWith(`:${port}`) ? host : `${host}:${port}`));
}

export function parseHttpUrl(raw: string): URL {
  const prepared = ensureHttpScheme(raw);
  if (prepared.includes("#")) throw new EndpointError("URL 不能包含 fragment");
  let url: URL;
  try {
    url = new URL(prepared);
  } catch {
    throw new EndpointError("URL 格式无效");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new EndpointError("URL 仅支持 HTTP 或 HTTPS");
  }
  if (!url.hostname) throw new EndpointError("URL 必须包含主机名");
  if (url.username || url.password) throw new EndpointError("URL 不能包含用户名或密码");
  return url;
}

function apiPrefix(url: URL): string {
  const path = url.pathname.replace(/\/+$/, "");
  if (path.endsWith(CHAT_SUFFIX) || path.endsWith(TOOLS_SUFFIX)) {
    return path.replace(/\/v1\/chat(?:vcp)?\/completions$/, "");
  }
  if (path.endsWith("/v1")) return path.slice(0, -3);
  return path;
}

function withSuffix(raw: string, suffix: string): string {
  const port = explicitDefaultPort(ensureHttpScheme(raw));
  const url = parseHttpUrl(raw);
  const prefix = apiPrefix(url);
  url.pathname = `${prefix}${suffix}` || suffix;
  url.search = "";
  url.hash = "";
  return reinstatePort(url.toString(), port);
}

export function resolveChatEndpoint(raw: string, mode: EndpointMode): string {
  return withSuffix(raw, mode === "vcp-tools" ? TOOLS_SUFFIX : CHAT_SUFFIX);
}

export function resolveModelsEndpoint(raw: string): string {
  return withSuffix(raw, MODELS_SUFFIX);
}

export function resolveServerOrigin(raw: string): URL {
  const chat = resolveChatEndpoint(raw, "standard");
  const url = new URL(chat);
  url.pathname = url.pathname.replace(/\/v1\/chat\/completions$/, "/") || "/";
  url.search = "";
  url.hash = "";
  return url;
}

export function adminUrl(raw: string, segments: string[]): string {
  const url = resolveServerOrigin(raw);
  const base = url.toString().replace(/\/$/, "");
  const parts = ["admin_api", ...segments].map((segment) => encodeURIComponent(segment));
  return `${base}/${parts.join("/")}`;
}

export function dailyNoteUrl(raw: string, segments: string[]): string {
  return adminUrl(raw, ["dailynotes", ...segments]);
}

function toWebSocketBase(raw: string): URL {
  let base = raw.trim();
  if (!base) throw new EndpointError("WebSocket 地址不能为空");
  if (hasControl(base)) throw new EndpointError("URL 不能包含控制字符");
  if (/^https:\/\//i.test(base)) base = `wss://${base.slice("https://".length)}`;
  else if (/^http:\/\//i.test(base)) base = `ws://${base.slice("http://".length)}`;
  else if (!/^wss?:\/\//i.test(base)) base = `ws://${base}`;
  if (base.includes("#")) throw new EndpointError("URL 不能包含 fragment");
  let url: URL;
  try {
    url = new URL(base);
  } catch {
    throw new EndpointError("WebSocket 地址无效");
  }
  if (url.protocol !== "ws:" && url.protocol !== "wss:") {
    throw new EndpointError("WebSocket 仅支持 ws 或 wss");
  }
  if (!url.hostname) throw new EndpointError("WebSocket 地址必须包含主机名");
  if (url.username || url.password) throw new EndpointError("WebSocket 地址不能包含用户名或密码");
  return url;
}

export function assertSocketKey(key: string): string {
  const trimmed = key.trim();
  if (!trimmed) throw new EndpointError("WebSocket 密钥不能为空");
  if (hasControl(trimmed) || /[\s/\\?#]/.test(trimmed)) {
    throw new EndpointError("WebSocket 密钥不能包含空白、斜杠或 ?#");
  }
  return trimmed;
}

export function buildLogSocketUrl(raw: string, key: string, deviceName = "VCPChat-iOS"): string {
  const safeKey = assertSocketKey(key);
  const port = explicitDefaultPort(raw.trim().match(/^[a-z]+:/i) ? raw.trim() : `ws://${raw.trim()}`);
  const url = toWebSocketBase(raw);
  let path = decodeURI(url.pathname).replace(/\/+$/, "");
  if (!path.includes("/VCPlog")) path = `${path}/VCPlog`;
  if (!path.includes("VCP_Key=")) path = `${path}/VCP_Key=${safeKey}`;
  url.pathname = path;
  url.search = "";
  url.hash = "";
  const next = new URL(reinstatePort(url.toString(), port));
  if (!next.searchParams.has("deviceName")) next.searchParams.set("deviceName", deviceName);
  return next.toString();
}

export function buildInfoSocketUrl(raw: string, key: string): string {
  const safeKey = assertSocketKey(key);
  const port = explicitDefaultPort(raw.trim().match(/^[a-z]+:/i) ? raw.trim() : `ws://${raw.trim()}`);
  const url = toWebSocketBase(raw);
  url.pathname = `/vcpinfo/VCP_Key=${safeKey}`;
  url.search = "";
  url.hash = "";
  return reinstatePort(url.toString(), port);
}

export function basicAuthorization(username: string, password: string): string {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `Basic ${btoa(binary)}`;
}
