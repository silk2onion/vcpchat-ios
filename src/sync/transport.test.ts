import { expect, test } from "vitest";
import { SyncHttp } from "./transport";
import type { HttpClient } from "../protocol/http";
const client = (status: number, body: string): HttpClient => ({
  request: async () => ({ status, body }),
});
test("truncated, duplicate-key and unacknowledged NDJSON are rejected", async () => {
  for (const body of [
    '{"ok":true}',
    '{"ok":true,"ok":false}\n',
    '{"ok":false,"error":{"code":"CAS_CONFLICT","message":"已改变"}}\n',
  ])
    await expect(
      new SyncHttp(
        client(200, body),
        "http://fixture",
        "token",
        new AbortController().signal,
      ).ndjson("/messages/pull", {}),
    ).rejects.toThrow();
});
test("authentication failures retain the upstream diagnostic and cancellation prevents applying a response", async () => {
  await expect(
    new SyncHttp(
      client(401, '{"error":{"code":"UNAUTHORIZED","message":"Token无效"}}'),
      "http://fixture",
      "token",
      new AbortController().signal,
    ).json("/entities/pull", {}),
  ).rejects.toThrow("UNAUTHORIZED：Token无效");
  const controller = new AbortController();
  controller.abort();
  await expect(
    new SyncHttp(
      client(200, '{"results":[]}'),
      "http://fixture",
      "token",
      controller.signal,
    ).json("/entities/pull", {}),
  ).rejects.toThrow("已取消");
});
