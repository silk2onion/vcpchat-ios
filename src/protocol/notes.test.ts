import { describe, expect, test } from "vitest";
import { defaultSettings, type Settings } from "../domain";
import type { HttpClient } from "./http";
import { listNoteFolders, listRemoteNotes, normalizeNoteFileName, readRemoteNote, saveRemoteNote, searchRemoteNotes } from "./notes";

function settings(): Settings {
  return {
    ...defaultSettings(),
    serverUrl: "http://127.0.0.1:6005/v1/chat/completions",
    adminUsername: "nova",
    adminPassword: "fixture-pass",
    apiKey: "fixture-key",
  };
}

function mockHttp(handler: (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => { status: number; body: string }): HttpClient {
  return {
    request: async ({ method, url, headers, body }) => handler(url, { method, headers, body }),
  };
}

describe("daily notes", () => {
  test("lists folders with basic auth and never echoes the password in errors", async () => {
    const http = mockHttp((url, init) => {
      expect(url).toBe("http://127.0.0.1:6005/admin_api/dailynotes/folders");
      expect(init.headers.Authorization.startsWith("Basic ")).toBe(true);
      expect(init.headers.Authorization).not.toContain("fixture-pass");
      return { status: 401, body: JSON.stringify({ error: "bad fixture-pass" }) };
    });
    await expect(listNoteFolders(settings(), http)).rejects.toThrow(/••••/);
  });

  test("reads, saves, and searches notes", async () => {
    const calls: string[] = [];
    const http = mockHttp((url, init) => {
      calls.push(`${init.method} ${url}`);
      if (url.endsWith("/folder/Daily")) return { status: 200, body: JSON.stringify({ notes: [{ name: "a.txt", preview: "hi", lastModified: "t" }] }) };
      if (url.includes("/note/Daily/a.txt") && init.method === "GET") return { status: 200, body: JSON.stringify({ content: "正文" }) };
      if (init.method === "POST") {
        expect(JSON.parse(init.body ?? "{}")).toEqual({ content: "新正文" });
        return { status: 200, body: "{}" };
      }
      if (url.includes("/search?")) return { status: 200, body: JSON.stringify({ notes: [{ name: "a.txt", folderName: "Daily", preview: "x" }] }) };
      return { status: 404, body: "{}" };
    });
    const notes = await listRemoteNotes(settings(), http, "Daily");
    expect(notes[0]).toMatchObject({ folder: "Daily", file: "a.txt", preview: "hi" });
    expect(await readRemoteNote(settings(), http, "Daily", "a.txt")).toBe("正文");
    await saveRemoteNote(settings(), http, "Daily", "a.txt", "新正文");
    const found = await searchRemoteNotes(settings(), http, "天气", "Daily");
    expect(found[0].file).toBe("a.txt");
    expect(calls.some((call) => call.startsWith("POST "))).toBe(true);
  });

  test("rejects path traversal and adds a text extension", () => {
    expect(normalizeNoteFileName("晨记")).toBe("晨记.txt");
    expect(() => normalizeNoteFileName("../secret")).toThrow(/无效/);
    expect(() => normalizeNoteFileName("a/b")).toThrow(/无效/);
  });
});
