import { mobileFileManifest, invokeMobileFileTool } from "./connected";
export interface FileNodeConfig {
  url: string;
  key: string;
  name: string;
  deviceId: string;
}
export function fileNodeUrl(raw: string, key: string): string {
  const u = new URL(raw);
  if (
    !["http:", "https:", "ws:", "wss:"].includes(u.protocol) ||
    u.username ||
    u.password ||
    u.search ||
    u.hash
  )
    throw new Error("请填写不带密钥和查询参数的 VCP 地址");
  if (!key.trim()) throw new Error("请填写 VCP 分布式 Key");
  u.protocol = ["https:", "wss:"].includes(u.protocol) ? "wss:" : "ws:";
  u.pathname =
    u.pathname.replace(/\/+$/, "").replace(/\/vcp-distributed-server$/, "") +
    "/vcp-distributed-server/VCP_Key=" +
    encodeURIComponent(key);
  return u.toString();
}
export class MobileFileNode {
  private socket: WebSocket | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = true;
  private pending = new Set<string>();
  constructor(
    private config: FileNodeConfig,
    private status: (value: string) => void,
    private execute: (
      args: unknown,
      id: string,
    ) => Promise<unknown> = invokeMobileFileTool,
    private open: (url: string) => WebSocket = (url) => new WebSocket(url),
  ) {}
  start() {
    this.stopped = false;
    this.connect();
  }
  private connect() {
    if (this.stopped) return;
    const manifest = mobileFileManifest(this.config.deviceId);
    this.status("连接中");
    const socket = this.open(fileNodeUrl(this.config.url, this.config.key));
    this.socket = socket;
    socket.onopen = () => {
      if (this.stopped || this.socket !== socket) {
        socket.close();
        return;
      }
      socket.send(
        JSON.stringify({
          type: "register_tools",
          data: {
            serverName: this.config.name.trim() || "VCPChat Mobile",
            tools: [manifest],
          },
        }),
      );
      this.status("已连接");
    };
    socket.onmessage = (event) => {
      if (this.stopped || socket !== this.socket) return;
      void this.handle(String(event.data), manifest.name, socket);
    };
    socket.onerror = () => {
      if (!this.stopped && this.socket === socket)
        this.status("连接失败，请检查地址与 Key");
    };
    socket.onclose = () => {
      if (!this.stopped && this.socket === socket) {
        this.status("已断开，稍后重连");
        this.timer = setTimeout(() => this.connect(), 3000);
      }
    };
  }
  private async handle(raw: string, toolName: string, socket: WebSocket) {
    if (raw.length > 30_000_000) {
      this.status("请求过大，未执行");
      return;
    }
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw);
    } catch {
      this.status("收到无效请求，未执行");
      return;
    }
    if (
      message.type !== "execute_tool" ||
      !message.data ||
      typeof message.data !== "object"
    )
      return;
    const data = message.data as Record<string, unknown>,
      id = data.requestId;
    if (
      typeof id !== "string" ||
      !id ||
      id.length > 160 ||
      data.toolName !== toolName
    )
      return;
    if (this.pending.has(id)) return;
    this.pending.add(id);
    let answer: Record<string, unknown>;
    try {
      const result = await this.execute(data.toolArgs, id);
      answer = { requestId: id, status: "success", result };
    } catch (error) {
      answer = {
        requestId: id,
        status: "error",
        error: error instanceof Error ? error.message : String(error),
      };
    } finally {
      this.pending.delete(id);
    }
    if (
      !this.stopped &&
      this.socket === socket &&
      socket.readyState === WebSocket.OPEN
    )
      socket.send(JSON.stringify({ type: "tool_result", data: answer }));
  }
  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.socket?.close();
    this.socket = null;
    this.status("未连接");
  }
}
