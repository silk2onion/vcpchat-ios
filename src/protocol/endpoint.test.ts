import { describe, expect, test } from "vitest";
import {
  adminUrl,
  buildInfoSocketUrl,
  buildLogSocketUrl,
  dailyNoteUrl,
  resolveChatEndpoint,
  resolveModelsEndpoint,
  resolveServerOrigin,
} from "./endpoint";

describe("chat endpoints", () => {
  test("strips an existing completions suffix and keeps a non-default port", () => {
    expect(resolveChatEndpoint("http://192.168.1.2:8080/v1/chat/completions", "standard")).toBe(
      "http://192.168.1.2:8080/v1/chat/completions",
    );
    expect(resolveModelsEndpoint("http://192.168.1.2:8080/v1/chat/completions")).toBe("http://192.168.1.2:8080/v1/models");
    expect(resolveServerOrigin("http://192.168.1.2:8080/v1/chat/completions").toString()).toBe("http://192.168.1.2:8080/");
  });

  test("keeps a custom base path and can switch to the VCP tools route", () => {
    expect(resolveChatEndpoint("https://example.com/vcp/", "standard")).toBe("https://example.com/vcp/v1/chat/completions");
    expect(resolveChatEndpoint("https://example.com/vcp/v1", "vcp-tools")).toBe("https://example.com/vcp/v1/chatvcp/completions");
  });

  test("adds http when the scheme is omitted and preserves an explicit default port", () => {
    expect(resolveChatEndpoint("host:6005", "standard")).toBe("http://host:6005/v1/chat/completions");
    expect(resolveChatEndpoint("http://host:80/v1", "standard")).toBe("http://host:80/v1/chat/completions");
  });

  test("accepts IPv6 and rejects embedded credentials, fragments, and other schemes", () => {
    expect(resolveModelsEndpoint("http://[::1]:6005")).toBe("http://[::1]:6005/v1/models");
    expect(() => resolveChatEndpoint("http://user:pass@host:8080", "standard")).toThrow(/用户名或密码/);
    expect(() => resolveChatEndpoint("http://host/v1#frag", "standard")).toThrow(/fragment/);
    expect(() => resolveChatEndpoint("ftp://host", "standard")).toThrow(/HTTP/);
    expect(() => resolveChatEndpoint("", "standard")).toThrow(/不能为空/);
  });

  test("builds admin and daily-note URLs with encoding", () => {
    expect(adminUrl("http://localhost:8080/v1/chat/completions", ["server-log"])).toBe(
      "http://localhost:8080/admin_api/server-log",
    );
    expect(dailyNoteUrl("http://localhost:8080", ["folder", "任务 A"])).toBe(
      "http://localhost:8080/admin_api/dailynotes/folder/%E4%BB%BB%E5%8A%A1%20A",
    );
  });
});

describe("socket endpoints", () => {
  test("matches the desktop VCPLog path and device name", () => {
    expect(buildLogSocketUrl("ws://192.168.1.8:6005", "fixture-key")).toBe(
      "ws://192.168.1.8:6005/VCPlog/VCP_Key=fixture-key?deviceName=VCPChat-iOS",
    );
    expect(buildLogSocketUrl("http://192.168.1.8:6005/VCPlog/", "fixture-key")).toBe(
      "ws://192.168.1.8:6005/VCPlog/VCP_Key=fixture-key?deviceName=VCPChat-iOS",
    );
  });

  test("builds the VCP info channel without putting the key in the query", () => {
    expect(buildInfoSocketUrl("ws://192.168.1.8:6005", "fixture-key")).toBe(
      "ws://192.168.1.8:6005/vcpinfo/VCP_Key=fixture-key",
    );
  });

  test("rejects keys that would break the path", () => {
    expect(() => buildLogSocketUrl("ws://host:6005", "")).toThrow(/密钥/);
    expect(() => buildLogSocketUrl("ws://host:6005", "bad key")).toThrow(/空白/);
    expect(() => buildLogSocketUrl("ws://user:secret@host:6005", "fixture-key")).toThrow(/用户名或密码/);
  });
});
