import crypto from "node:crypto";
import http from "node:http";

const port = Number(process.env.MOCK_VCP_PORT || 43124);
const notes = new Map([["Daily/hello.txt", "本地假服务器里的第一篇日记。"]]);

function cors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type, Accept");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
}

function sendJson(res, status, body) {
  cors(res);
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(body));
}

function authorized(req) {
  const header = req.headers.authorization || "";
  return header.startsWith("Bearer ") && header.trim().length > "Bearer ".length;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://127.0.0.1:${port}`);
  if (req.method === "OPTIONS") {
    cors(res);
    res.writeHead(204);
    res.end();
    return;
  }
  if (url.pathname === "/v1/models" && req.method === "GET") {
    if (!authorized(req)) return sendJson(res, 401, { error: { message: "missing bearer" } });
    return sendJson(res, 200, { data: [{ id: "vcp-demo" }] });
  }
  if ((url.pathname === "/v1/chat/completions" || url.pathname === "/v1/chatvcp/completions") && req.method === "POST") {
    if (!authorized(req)) return sendJson(res, 401, { error: { message: "missing bearer" } });
    cors(res);
    res.writeHead(200, { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache" });
    const frames = [
      { reasoning_content: "先看问题。" },
      { content: "这是一条**流式**回复。\n\n" },
      { content: "<<<[TOOL_REQUEST]>>>\ntool_name:「始」DailyNote「末」,\ncommand:「始」read「末」\n<<<[END_TOOL_REQUEST]>>>\n\n" },
      { content: "卡片上面是工具调用，下面仍是正文。" },
    ];
    for (const delta of frames) {
      res.write(`data: ${JSON.stringify({ choices: [{ delta }] })}\n\n`);
      await new Promise((resolve) => setTimeout(resolve, 120));
    }
    res.write("data: [DONE]\n\n");
    res.end();
    return;
  }
  if (url.pathname === "/admin_api/dailynotes/folders") {
    return sendJson(res, 200, { folders: ["Daily"] });
  }
  if (url.pathname === "/admin_api/dailynotes/folder/Daily") {
    return sendJson(res, 200, {
      notes: [...notes.keys()].filter((key) => key.startsWith("Daily/")).map((key) => ({ name: key.slice(6), preview: notes.get(key).slice(0, 24) })),
    });
  }
  const noteMatch = url.pathname.match(/^\/admin_api\/dailynotes\/note\/([^/]+)\/([^/]+)$/);
  if (noteMatch && req.method === "GET") {
    const key = `${decodeURIComponent(noteMatch[1])}/${decodeURIComponent(noteMatch[2])}`;
    return sendJson(res, 200, { content: notes.get(key) ?? "" });
  }
  if (noteMatch && req.method === "POST") {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const payload = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    const key = `${decodeURIComponent(noteMatch[1])}/${decodeURIComponent(noteMatch[2])}`;
    notes.set(key, String(payload.content ?? ""));
    return sendJson(res, 200, { ok: true });
  }
  if (url.pathname === "/admin_api/dailynotes/search") {
    const term = url.searchParams.get("term") || "";
    const found = [...notes.entries()]
      .filter(([, content]) => content.includes(term))
      .map(([key, content]) => ({ name: key.split("/")[1], folderName: key.split("/")[0], preview: content.slice(0, 24) }));
    return sendJson(res, 200, { notes: found, total: found.length });
  }
  sendJson(res, 404, { error: "not found" });
});

server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  const path = String(req.url || "");
  const isLog = path.includes("/VCPlog/VCP_Key=");
  const isInfo = path.includes("/vcpinfo/VCP_Key=");
  if (!key || (!isLog && !isInfo)) {
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    return;
  }
  const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  const payload = Buffer.from(
    JSON.stringify(
      isInfo
        ? { type: "vcp_info", message: "假的 VCPInfo 已接通" }
        : { type: "connection_ack", message: "假的 VCPLog 已接通" },
    ),
  );
  const frame = Buffer.alloc(2 + payload.length);
  frame[0] = 0x81;
  frame[1] = payload.length;
  payload.copy(frame, 2);
  socket.write(frame);
});

server.listen(port, "127.0.0.1", () => {
  console.log(`mock VCP listening on http://127.0.0.1:${port}`);
});
