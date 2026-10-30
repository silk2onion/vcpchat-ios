import { expect, test, vi } from "vitest";
import { ConnectedFiles, folderJoin, mobileFileManifest } from "./connected";
import type { NativeRequest } from "./connected";
import { defaultSettings, secretsOf } from "../domain";
test("native folder changes use opaque folder identity, expected version and unique receipts", async () => {
  const requests: Record<string, unknown>[] = [];
  const native: NativeRequest = async <T>(r: Record<string, unknown>) => {
    requests.push(r);
    return { path: "proof.txt", version: "new" } as T;
  };
  const client = new ConnectedFiles(native);
  await client.write("folder-one", "proof.txt", "修改", "original");
  await client.write("folder-one", "new.txt", "新内容");
  expect(requests[0]).toMatchObject({
    action: "execute",
    folderId: "folder-one",
    args: {
      command: "WriteFile",
      filePath: "proof.txt",
      expectedVersion: "original",
      overwrite: true,
    },
  });
  expect(requests[0].operationId).not.toBe(requests[1].operationId);
  expect(
    (requests[1].args as Record<string, unknown>).overwrite,
  ).toBeUndefined();
  expect(JSON.stringify(requests)).not.toContain("storage");
});
test("restore reads the current version before replacing anything", async () => {
  const requests: Record<string, unknown>[] = [];
  const native: NativeRequest = async <T>(r: Record<string, unknown>) => {
    requests.push(r);
    return { version: "current" } as T;
  };
  await new ConnectedFiles(native).restore("folder", {
    id: "backup",
    path: "a.txt",
    operation: "WriteFile",
    createdAt: 1,
    directory: false,
  });
  expect(requests[1]).toMatchObject({
    action: "restore",
    expectedVersion: "current",
    folderId: "folder",
    backupId: "backup",
  });
});
test("device manifests meet upstream registration requirements and cannot collide with desktop FileOperator", () => {
  const first = mobileFileManifest("device-a"),
    second = mobileFileManifest("device-b");
  expect(first.name).not.toBe(second.name);
  expect(first.name).not.toBe("FileOperator");
  expect(first.entryPoint).toBeTruthy();
  expect(first.pluginType).toBe("synchronous");
  expect(
    first.capabilities.invocationCommands.some(
      (c) => c.command === "DeleteFile",
    ),
  ).toBe(true);
  expect(JSON.stringify(first)).not.toContain("key");
  expect(() => folderJoin("root", "../outside")).toThrow();
  expect(folderJoin("", "笔记.txt")).toBe("笔记.txt");
});
test("node credentials are local defaults and participate in redaction", () => {
  const s = defaultSettings();
  expect(s.fileNodeEnabled).toBe(false);
  expect(s.fileNodeKey).toBe("");
  expect(secretsOf({ ...s, fileNodeKey: "fixture-node-secret" })).toContain(
    "fixture-node-secret",
  );
});
