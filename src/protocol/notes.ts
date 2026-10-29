import type { Settings } from "../domain";
import { dailyNoteUrl } from "./endpoint";
import { basicAuthorization } from "./endpoint";
import { formatHttpError, type HttpClient } from "./http";

export interface RemoteNote {
  folder: string;
  file: string;
  lastModified: string;
  preview: string;
}

export function assertPathSegment(value: string, label: string): string {
  const trimmed = value.trim();
  if (!trimmed || trimmed === "." || trimmed === ".." || /[\\/]/.test(trimmed) || [...trimmed].some((char) => char.charCodeAt(0) <= 31)) {
    throw new Error(`${label}无效`);
  }
  return trimmed;
}

export function normalizeNoteFileName(value: string): string {
  const name = assertPathSegment(value, "文件名");
  return name.includes(".") ? name : `${name}.txt`;
}

function authHeaders(settings: Settings, json = false): Record<string, string> {
  if (!settings.adminUsername.trim() || !settings.adminPassword) {
    throw new Error("读取服务器日记需要管理员用户名和密码");
  }
  return {
    Accept: "application/json",
    Authorization: basicAuthorization(settings.adminUsername.trim(), settings.adminPassword),
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

async function readJson(settings: Settings, response: { status: number; body: string }): Promise<unknown> {
  if (response.status < 200 || response.status >= 300) {
    throw new Error(formatHttpError(response.status, response.body, [settings.apiKey, settings.adminPassword, settings.logKey]));
  }
  if (!response.body.trim()) return {};
  try {
    return JSON.parse(response.body) as unknown;
  } catch {
    throw new Error("服务器返回了无法解析的 JSON");
  }
}

export async function listNoteFolders(settings: Settings, http: HttpClient): Promise<string[]> {
  const response = await http.request({
    method: "GET",
    url: dailyNoteUrl(settings.serverUrl, ["folders"]),
    headers: authHeaders(settings),
  });
  const json = (await readJson(settings, response)) as { folders?: unknown };
  if (!Array.isArray(json.folders)) throw new Error("文件夹列表格式不符合约定");
  return json.folders.filter((folder): folder is string => typeof folder === "string");
}

export async function listRemoteNotes(settings: Settings, http: HttpClient, folder: string): Promise<RemoteNote[]> {
  const safeFolder = assertPathSegment(folder, "文件夹");
  const response = await http.request({
    method: "GET",
    url: dailyNoteUrl(settings.serverUrl, ["folder", safeFolder]),
    headers: authHeaders(settings),
  });
  const json = (await readJson(settings, response)) as { notes?: unknown; memos?: unknown };
  const rows = Array.isArray(json.notes) ? json.notes : Array.isArray(json.memos) ? json.memos : null;
  if (!rows) throw new Error("笔记列表格式不符合约定");
  return rows.map((row) => normalizeSummary(row, safeFolder));
}

export async function readRemoteNote(settings: Settings, http: HttpClient, folder: string, file: string): Promise<string> {
  const safeFolder = assertPathSegment(folder, "文件夹");
  const safeFile = assertPathSegment(file, "文件名");
  const response = await http.request({
    method: "GET",
    url: dailyNoteUrl(settings.serverUrl, ["note", safeFolder, safeFile]),
    headers: authHeaders(settings),
  });
  const json = (await readJson(settings, response)) as { content?: unknown };
  if (typeof json.content !== "string") throw new Error("笔记正文格式不符合约定");
  return json.content;
}

export async function saveRemoteNote(
  settings: Settings,
  http: HttpClient,
  folder: string,
  file: string,
  content: string,
): Promise<void> {
  const safeFolder = assertPathSegment(folder, "文件夹");
  const safeFile = assertPathSegment(file, "文件名");
  const response = await http.request({
    method: "POST",
    url: dailyNoteUrl(settings.serverUrl, ["note", safeFolder, safeFile]),
    headers: authHeaders(settings, true),
    body: JSON.stringify({ content }),
  });
  await readJson(settings, response);
}

export async function searchRemoteNotes(settings: Settings, http: HttpClient, term: string, folder?: string): Promise<RemoteNote[]> {
  const query = term.trim();
  if (!query) return [];
  const url = new URL(dailyNoteUrl(settings.serverUrl, ["search"]));
  url.searchParams.set("term", query);
  if (folder?.trim()) url.searchParams.set("folder", assertPathSegment(folder, "文件夹"));
  const response = await http.request({
    method: "GET",
    url: url.toString(),
    headers: authHeaders(settings),
  });
  const json = (await readJson(settings, response)) as { notes?: unknown };
  if (!Array.isArray(json.notes)) return [];
  return json.notes.map((row) => normalizeSummary(row, folder));
}

function normalizeSummary(row: unknown, fallbackFolder?: string): RemoteNote {
  const record = row && typeof row === "object" ? (row as Record<string, unknown>) : {};
  const file = String(record.name ?? record.file ?? "");
  const folder = String(record.folderName ?? record.folder ?? fallbackFolder ?? "");
  return {
    folder,
    file,
    lastModified: String(record.lastModified ?? record.last_modified ?? ""),
    preview: String(record.preview ?? ""),
  };
}
