import type { Settings } from "../domain";
import { secretsOf } from "../domain";
import { createSyncHttp, binaryRequest } from "../sync/transport";
import { resolveModelsEndpoint } from "../protocol/endpoint";
import { redactSecrets } from "../protocol/redact";
import { object, string } from "../sync/projection";
import type { Json } from "../sync/types";
import { base64 } from "./bytes";
export interface RemoteFile {
  name: string;
  path: string;
  type: "file" | "directory";
  size: number | null;
  modified: string;
}
export function normalizePath(path: string): string {
  const value = path
    .trim()
    .replace(/\\/g, "/")
    .replace(/\/{2,}/g, "/");
  if (
    !value ||
    [...value].some((c) => c.charCodeAt(0) < 32) ||
    value.split("/").some((p) => p === "..") ||
    !/^(?:\/|[A-Za-z]:\/)/.test(value)
  )
    throw new Error("请填写服务器上的绝对路径");
  return /^[A-Za-z]:\/$/.test(value) ? value : value.replace(/\/$/, "") || "/";
}
export function within(root: string, path: string): boolean {
  let r = normalizePath(root),
    p = normalizePath(path);
  if (/^[a-z]:/i.test(r)) {
    r = r.toLowerCase();
    p = p.toLowerCase();
  }
  return p === r || p.startsWith(r.endsWith("/") ? r : r + "/");
}
export function joinPath(root: string, name: string): string {
  if (
    !name.trim() ||
    /[\\/]/.test(name) ||
    [...name].some((c) => c.charCodeAt(0) < 32) ||
    [".", ".."].includes(name.trim())
  )
    throw new Error("文件名不能带路径分隔符");
  return normalizePath(normalizePath(root) + "/" + name.trim());
}
export function toolBlock(
  tool: string,
  command: string,
  args: Record<string, string | number | boolean>,
): string {
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(tool)) throw new Error("文件工具名称无效");
  const values = { tool_name: tool, command, ...args };
  for (const value of Object.values(values))
    if (/「[始末]」|<<<|>>>/.test(String(value)))
      throw new Error("路径含工具协议标记，无法通过此接口操作");
  return (
    "<<<[TOOL_REQUEST]>>>\n" +
    Object.entries(values)
      .map(([k, v]) => `${k}:「始」${v}「末」`)
      .join(",\n") +
    "\n<<<[END_TOOL_REQUEST]>>>"
  );
}
export class FileClient {
  constructor(private readonly settings: Settings) {}
  async call(
    command: string,
    args: Record<string, string | number | boolean> = {},
  ): Promise<{ details: Json; content: Json[] }> {
    const s = this.settings;
    if (!s.apiKey.trim()) throw new Error("先在服务器设置中填写 API Key");
    try {
      const http = await createSyncHttp();
      const response = await http.request({
        method: "POST",
        url: resolveModelsEndpoint(s.serverUrl).replace(
          /\/v1\/models$/,
          "/v1/human/tool",
        ),
        headers: {
          Authorization: `Bearer ${s.apiKey}`,
          "Content-Type": "text/plain",
        },
        body: toolBlock(s.fileToolName, command, args),
      });
      const data = object(JSON.parse(response.body));
      if (
        response.status < 200 ||
        response.status >= 300 ||
        data.status === "error" ||
        data.success === false
      )
        throw new Error(
          typeof data.error === "string"
            ? data.error
            : `文件操作 HTTP ${response.status}`,
        );
      const result = object(data.result ?? data);
      const details = object(result.details ?? result.data ?? {});
      const content = Array.isArray(result.content)
        ? result.content.map(object)
        : [];
      if (data.status !== "success" && data.success !== true && !data.result)
        throw new Error("文件操作未返回成功状态");
      return { details, content };
    } catch (error) {
      throw new Error(
        redactSecrets(
          error instanceof Error ? error.message : String(error),
          secretsOf(s),
        ),
      );
    }
  }
  async roots(): Promise<string[]> {
    const { details } = await this.call("ListAllowedDirectories");
    return Object.keys(object(details.allowedRoots));
  }
  async list(
    path: string,
  ): Promise<{ items: RemoteFile[]; truncated: boolean }> {
    const root = normalizePath(this.settings.fileRoot);
    if (!within(root, path)) throw new Error("目标路径不在当前浏览起点内");
    const { details } = await this.call("ListDirectory", {
      directoryPath: normalizePath(path),
      showHidden: false,
    });
    if (!Array.isArray(details.items))
      throw new Error("服务器没有返回目录条目");
    const items = details.items.map((item) => {
      const r = object(item);
      const p = string(r.path);
      if (!within(root, p) || !["file", "directory"].includes(string(r.type)))
        throw new Error("服务器目录返回了范围外或无效条目");
      return {
        name: string(r.name),
        path: p,
        type: r.type as RemoteFile["type"],
        size: typeof r.size === "number" ? r.size : null,
        modified: string(r.lastModified),
      };
    });
    return { items, truncated: details.truncated === true };
  }
  async read(file: RemoteFile): Promise<{ text: string; image: string }> {
    this.check(file.path);
    const { content } = await this.call("ReadFile", { filePath: file.path });
    const img = content.find((p) => p.type === "image_url");
    const url = img ? string(object(img.image_url).url) : "";
    return {
      text: content
        .filter((p) => p.type === "text")
        .map((p) => string(p.text))
        .join("\n\n"),
      image: /^data:image\/(png|jpeg|gif|webp);base64,/i.test(url) ? url : "",
    };
  }
  check(path: string) {
    if (!within(this.settings.fileRoot, path))
      throw new Error("目标路径不在当前浏览起点内");
  }
  async rename(
    source: string,
    destination: string,
    copy = false,
    move = false,
  ) {
    this.check(source);
    this.check(destination);
    if (move) {
      let exists = false;
      try {
        await this.call("FileInfo", { filePath: destination });
        exists = true;
      } catch (e) {
        if (
          !/ENOENT|not found|不存在/i.test(
            e instanceof Error ? e.message : String(e),
          )
        )
          throw e;
      }
      if (exists) throw new Error("目标已存在，未移动或覆盖");
    }
    return this.call(copy ? "CopyFile" : move ? "MoveFile" : "RenameFile", {
      sourcePath: source,
      destinationPath: destination,
    });
  }
  async remove(path: string) {
    this.check(path);
    return this.call("DeleteFile", { filePath: path });
  }
  async folder(path: string) {
    this.check(path);
    return this.call("CreateDirectory", { directoryPath: path });
  }
  async upload(path: string, bytes: Uint8Array) {
    this.check(path);
    if (bytes.length > 10_000_000) throw new Error("此工具单次上传上限为10MB");
    return this.call("WriteFile", {
      filePath: path,
      content: base64(bytes),
      encoding: "base64",
    });
  }
  async download(file: RemoteFile): Promise<Uint8Array> {
    const s = this.settings;
    this.check(file.path);
    if (!s.fileKey.trim() || !s.fileShareRoot.trim())
      throw new Error("下载原文件需要填写 File Key 和服务端 file/ 目录映射");
    const shared = normalizePath(s.fileShareRoot),
      path = normalizePath(file.path);
    if (!within(shared, path))
      throw new Error(
        "此文件不在服务端 file/ 分发目录内，可读取提取内容或先复制到分发目录",
      );
    const relative = path
      .slice(shared.length)
      .replace(/^\//, "")
      .split("/")
      .map(encodeURIComponent)
      .join("/");
    const base = resolveModelsEndpoint(s.serverUrl).replace(
      /\/v1\/models$/,
      "",
    );
    try {
      return await binaryRequest(
        `${base}/pw=${encodeURIComponent(s.fileKey)}/files/${relative}`,
        {},
      );
    } catch (error) {
      throw new Error(
        redactSecrets(error instanceof Error ? error.message : String(error), [
          ...secretsOf(s),
          encodeURIComponent(s.fileKey),
        ]),
      );
    }
  }
}
