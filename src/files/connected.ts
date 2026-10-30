import { isTauri } from "../protocol/http";
export type FolderAccess = "off" | "read" | "write";
export interface ConnectedFolder {
  id: string;
  name: string;
  agentAccess: FolderAccess;
}
export interface FolderEntry {
  name: string;
  path: string;
  type: "file" | "directory" | "symlink" | "missing";
  size: number;
  modified: number;
  version?: string;
  text?: string;
  base64?: string;
}
export interface FolderBackup {
  id: string;
  path: string;
  operation: string;
  createdAt: number;
  directory: boolean;
}
export interface FolderResult {
  path: string;
  version: string;
  backupId?: string;
}
export type NativeRequest = <T>(request: Record<string, unknown>) => Promise<T>;
async function native<T>(request: Record<string, unknown>): Promise<T> {
  if (!isTauri()) throw new Error("连接文件夹需要使用 Mac 或 iOS App");
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke("folder_request", { request });
}
export class ConnectedFiles {
  constructor(private readonly request: NativeRequest = native) {}
  folders() {
    return this.request<ConnectedFolder[]>({ action: "folders" });
  }
  connect() {
    return this.request<ConnectedFolder | { canceled: true }>({
      action: "connect",
    });
  }
  disconnect(folderId: string) {
    return this.request({ action: "disconnect", folderId });
  }
  grant(folderId: string, access: FolderAccess) {
    return this.request<ConnectedFolder>({ action: "grant", folderId, access });
  }
  execute<T>(
    folderId: string,
    args: Record<string, unknown>,
    operationId = crypto.randomUUID(),
  ) {
    return this.request<T>({ action: "execute", folderId, args, operationId });
  }
  list(folderId: string, path = "") {
    return this.execute<{ items: FolderEntry[]; truncated: boolean }>(
      folderId,
      { command: "ListDirectory", directoryPath: path },
    );
  }
  read(folderId: string, path: string) {
    return this.execute<FolderEntry>(folderId, {
      command: "ReadFile",
      filePath: path,
    });
  }
  info(folderId: string, path: string) {
    return this.execute<FolderEntry>(folderId, {
      command: "FileInfo",
      filePath: path,
    });
  }
  write(
    folderId: string,
    path: string,
    content: string,
    version?: string,
    encoding = "utf8",
  ) {
    return this.execute<FolderResult>(folderId, {
      command: "WriteFile",
      filePath: path,
      content,
      encoding,
      ...(version ? { overwrite: true, expectedVersion: version } : {}),
    });
  }
  folder(folderId: string, path: string) {
    return this.execute<FolderResult>(folderId, {
      command: "CreateDirectory",
      directoryPath: path,
    });
  }
  backups(folderId: string) {
    return this.request<FolderBackup[]>({ action: "backups", folderId });
  }
  async restore(folderId: string, backup: FolderBackup) {
    const current = await this.info(folderId, backup.path);
    return this.request<FolderResult>({
      action: "restore",
      folderId,
      backupId: backup.id,
      expectedVersion: current.version,
    });
  }
}
export const connectedFiles = new ConnectedFiles();
export function folderJoin(parent: string, name: string) {
  if (
    !name.trim() ||
    /[\\/]/.test(name) ||
    name.trim() === "." ||
    name.trim() === ".."
  )
    throw new Error("请填写文件名，不要包含路径分隔符");
  return parent ? parent + "/" + name.trim() : name.trim();
}
export const mobileCommands = [
  "ListAllowedDirectories",
  "ListDirectory",
  "FileInfo",
  "ReadFile",
  "WriteFile",
  "AppendFile",
  "EditFile",
  "CopyFile",
  "MoveFile",
  "RenameFile",
  "DeleteFile",
  "CreateDirectory",
] as const;
export function mobileFileManifest(deviceId: string) {
  const suffix = deviceId.replace(/[^a-zA-Z0-9]/g, "");
  if (!suffix || suffix.length > 80) throw new Error("设备标识无效");
  return {
    name: `MobileFileOperator_${suffix}`,
    displayName: "移动文件操作器",
    pluginType: "synchronous",
    entryPoint: { command: "native:connected-folders" },
    communication: { protocol: "direct", timeout: 120000 },
    version: "1.0.0",
    description:
      "直接操作本设备经用户连接并授权的文件夹，修改前保存备份。所有路径必须相对于folderId；不访问未授权目录。",
    capabilities: {
      invocationCommands: mobileCommands.map((command) => ({
        command,
        description:
          command === "ListAllowedDirectories"
            ? "列出已授权Agent的文件夹id、名称和权限，不返回系统绝对路径。"
            : "必需folderId。ListDirectory用directoryPath（根目录空字符串）；文件用filePath；复制/移动/改名用sourcePath与destinationPath。所有路径为相对路径。ReadFile上限200KB；修改操作先ReadFile或FileInfo取得expectedVersion。WriteFile用content、encoding(utf8/base64)，覆盖须overwrite:true；EditFile用oldText及content作单次唯一替换。修改文件上限20MB，目录备份上限100MB/2000项。同名目标不覆盖，失败返回错误。",
      })),
    },
  };
}
export async function invokeMobileFileTool(
  args: unknown,
  requestId: string,
): Promise<unknown> {
  if (!args || typeof args !== "object" || Array.isArray(args))
    throw new Error("文件工具参数无效");
  const input = { ...(args as Record<string, unknown>) };
  if (input.overwrite !== undefined)
    input.overwrite = input.overwrite === true || input.overwrite === "true";
  if (
    !mobileCommands.includes(input.command as (typeof mobileCommands)[number])
  )
    throw new Error("移动文件操作器不支持这项指令");
  const { invoke } = await import("@tauri-apps/api/core");
  const details = await invoke<Record<string, unknown>>("folder_tool", {
    args: input,
    requestId,
  });
  const text =
    typeof details.text === "string" ? details.text : JSON.stringify(details);
  return {
    status: "success",
    result: { content: [{ type: "text", text }], details },
  };
}
