import { expect, test, vi } from "vitest";
import { MobileFileNode, fileNodeUrl } from "./node";
class Socket {
  readyState = 1;
  sent: string[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  send(v: string) {
    this.sent.push(v);
  }
  close() {
    this.readyState = 3;
    this.onclose?.();
  }
}
const config = {
  url: "http://127.0.0.1:6005",
  key: "fixture-key",
  name: "Mac验收",
  deviceId: "device-test",
};
const turn = () => new Promise((r) => setTimeout(r, 0));
test("distributed node registers and returns real tool results using the original VCP envelope", async () => {
  const socket = new Socket(),
    statuses: string[] = [],
    execute = vi
      .fn()
      .mockResolvedValue({
        status: "success",
        result: { details: { path: "a.txt", backupId: "before" } },
      });
  const node = new MobileFileNode(
    config,
    (v) => statuses.push(v),
    execute,
    () => socket as unknown as WebSocket,
  );
  node.start();
  socket.onopen?.();
  const registration = JSON.parse(socket.sent[0]);
  expect(registration).toMatchObject({
    type: "register_tools",
    data: {
      serverName: "Mac验收",
      tools: [
        {
          name: "MobileFileOperator_devicetest",
          entryPoint: { command: "native:connected-folders" },
        },
      ],
    },
  });
  socket.onmessage?.({
    data: JSON.stringify({
      type: "execute_tool",
      data: {
        requestId: "one",
        toolName: registration.data.tools[0].name,
        toolArgs: { command: "WriteFile", folderId: "folder", content: "正文" },
      },
    }),
  });
  await turn();
  expect(execute).toHaveBeenCalledWith(
    { command: "WriteFile", folderId: "folder", content: "正文" },
    "one",
  );
  expect(JSON.parse(socket.sent[1])).toMatchObject({
    type: "tool_result",
    data: {
      requestId: "one",
      status: "success",
      result: { result: { details: { backupId: "before" } } },
    },
  });
  expect(statuses).toContain("已连接");
  node.stop();
});
test("wrong-device calls do not execute; permission errors return failure instead of fake success", async () => {
  const socket = new Socket(),
    execute = vi.fn().mockRejectedValue(new Error("NOT_AUTHORIZED"));
  const node = new MobileFileNode(
    config,
    () => {},
    execute,
    () => socket as unknown as WebSocket,
  );
  node.start();
  socket.onopen?.();
  socket.onmessage?.({
    data: JSON.stringify({
      type: "execute_tool",
      data: {
        requestId: "wrong",
        toolName: "FileOperator",
        toolArgs: { command: "DeleteFile" },
      },
    }),
  });
  await turn();
  expect(execute).not.toHaveBeenCalled();
  socket.onmessage?.({
    data: JSON.stringify({
      type: "execute_tool",
      data: {
        requestId: "two",
        toolName: "MobileFileOperator_devicetest",
        toolArgs: { command: "DeleteFile" },
      },
    }),
  });
  await turn();
  expect(JSON.parse(socket.sent.at(-1)!)).toMatchObject({
    type: "tool_result",
    data: { requestId: "two", status: "error", error: "NOT_AUTHORIZED" },
  });
  node.stop();
});
test("duplicate in-flight requests execute once and stopping prevents sending late results", async () => {
  const socket = new Socket();
  let complete: (v: unknown) => void = () => {};
  const execute = vi.fn(
    () =>
      new Promise((r) => {
        complete = r;
      }),
  );
  const node = new MobileFileNode(
    config,
    () => {},
    execute,
    () => socket as unknown as WebSocket,
  );
  node.start();
  socket.onopen?.();
  const call = JSON.stringify({
    type: "execute_tool",
    data: {
      requestId: "same",
      toolName: "MobileFileOperator_devicetest",
      toolArgs: { command: "WriteFile" },
    },
  });
  socket.onmessage?.({ data: call });
  socket.onmessage?.({ data: call });
  expect(execute).toHaveBeenCalledTimes(1);
  node.stop();
  complete({ done: true });
  await turn();
  expect(socket.sent).toHaveLength(1);
});
test("connection URLs follow VCP routing without accepting embedded credentials", () => {
  expect(fileNodeUrl(config.url, "a/b")).toBe(
    "ws://127.0.0.1:6005/vcp-distributed-server/VCP_Key=a%2Fb",
  );
  expect(fileNodeUrl("https://example.test/vcp-distributed-server/", "k")).toBe(
    "wss://example.test/vcp-distributed-server/VCP_Key=k",
  );
  expect(() => fileNodeUrl("https://user:pass@example.test", "k")).toThrow();
  expect(() => fileNodeUrl(config.url, "")).toThrow();
});
