import { redactSecrets } from "./redact";

export interface HttpResponse {
  status: number;
  body: string;
}

export interface HttpClient {
  request(input: { method: string; url: string; headers: Record<string, string>; body?: string }): Promise<HttpResponse>;
}

export function formatHttpError(status: number, body: string, secrets: readonly string[]): string {
  let detail = body.trim();
  try {
    const json = JSON.parse(body) as { error?: { message?: string } | string; message?: string };
    if (typeof json.error === "string") detail = json.error;
    else if (json.error && typeof json.error.message === "string") detail = json.error.message;
    else if (typeof json.message === "string") detail = json.message;
  } catch {
    // Keep the raw body when it is not JSON.
  }
  detail = detail.replace(/\s+/g, " ").slice(0, 300);
  return redactSecrets(`HTTP ${status}${detail ? `：${detail}` : ""}`, secrets);
}

export function createBrowserHttp(): HttpClient {
  return {
    async request({ method, url, headers, body }) {
      const response = await fetch(url, { method, headers, body });
      return { status: response.status, body: await response.text() };
    },
  };
}

export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export async function createAppHttp(): Promise<HttpClient> {
  if (!isTauri()) return createBrowserHttp();
  const { invoke } = await import("@tauri-apps/api/core");
  return {
    async request({ method, url, headers, body }) {
      return invoke<HttpResponse>("http_request", { method, url, headers, body: body ?? null });
    },
  };
}
