"""Loopback-only, gated SSE fixture for the simulator's system URLSession daemon."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class Gates:
    def __init__(self):
        self.next_frame = threading.Event()
        self.finish = threading.Event()
        self.count = 0


gates = {"": Gates(), "/ui": Gates()}


class Reply(BaseHTTPRequestHandler):
    def route(self):
        prefix = "/ui" if self.path.startswith("/ui/") else ""
        return gates[prefix], self.path[len(prefix):]

    def do_GET(self):
        gate, path = self.route()
        if path == "/next":
            gate.next_frame.set()
        elif path == "/finish":
            gate.finish.set()
        elif path != "/count":
            self.send_error(404)
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(str(gate.count).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/group-fc/v1/chat/completions":
            # Mirror the backend wire contract: one status turn per call ID,
            # followed by ONE batch containing both tools' named result bodies.
            def call(ident, arguments):
                return {"id": ident, "type": "function", "function": {"name": "vcptools",
                        "arguments": json.dumps(arguments, ensure_ascii=False)}}
            diary = call("call_note", {"tool_name": "DailyNote", "command": "create", "maid": "A",
                         "fileName": "海边手记", "folder": "旅行", "Content": "今天在海边记录了潮位。", "Tag": "潮位"})
            calc = call("call_math", {"tool_name": "Calculator", "expression": "17*19"})
            def result(tool, value):
                return f"[[VCP调用结果信息汇总:\n工具名称: {tool}\n执行状态: 成功\n返回内容: {value}\nVCP调用结果结束]]"
            batch = "\n".join(["<<<[VCP_TOOL_BATCH_START:1]>>>", result("DailyNote", "note-407"),
                               result("Calculator", "323"), "<<<[VCP_TOOL_BATCH_END:1]>>>"])
            history = [m for m in body["messages"] if m["role"] != "system"]
            system = "\n".join(m["content"] for m in body["messages"] if m["role"] == "system")
            def delta(**values):
                return {"choices": [{"delta": values}]}
            if len(history) == 1 and "你的名字是「A」" in system:
                frames = [delta(content="并行查询。"), delta(tool_calls=[dict(calc, index=1), dict(diary, index=0)]),
                          delta(content=batch), delta(content="已收到两份回执。")]
            elif ("你的名字是「B」" in system and len(history) == 7 and history[0]["role"] == history[-1]["role"] == "user"
                  and history[1:-1] == [
                      {"role": "assistant", "content": "【A】\n并行查询。", "tool_calls": [diary, calc]},
                      {"role": "tool", "tool_call_id": "call_note", "content": "原始结果保留上下文摘要"},
                      {"role": "tool", "tool_call_id": "call_math", "content": "原始结果保留上下文摘要"},
                      {"role": "user", "content": batch}, {"role": "assistant", "content": "【A】\n已收到两份回执。"}]):
                frames = [delta(content="日记编号 note-407，计算结果 323。")]
            else:
                print("Unexpected group fixture history:", history, system, flush=True)
                self.send_error(422, "incorrect speaker, call IDs or receipt bodies")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for frame in frames:
                self.wfile.write(("data: " + json.dumps(frame, ensure_ascii=False) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        if self.path == "/fc/v1/chat/completions":
            history = [m for m in body["messages"] if m["role"] != "system"]
            args = '{"tool_name":"天气","city":"青岛","note":"<em>原文</em>"}'
            call = {"id": "call_weather", "type": "function", "function": {"name": "vcp", "arguments": args}}
            batch = "<<<[VCP_TOOL_BATCH_START:fc]>>>\n晴，18°C\n<<<[VCP_TOOL_BATCH_END:fc]>>>"
            def delta(**values):
                return {"choices": [{"delta": values}]}
            if len(history) == 1:
                frames = [delta(content="我查一下。"),
                          delta(tool_calls=[{**call, "index": 0, "function": {"name": "v", "arguments": args[:12]}}]),
                          delta(tool_calls=[{"index": 0, "function": {"name": "cp", "arguments": args[12:]}}]),
                          {"choices": [{"finish_reason": "tool_calls", "delta": {}}]},
                          delta(content=batch), delta(content="青岛今天晴。")]
            else:
                expected = [{"role": "assistant", "content": "我查一下。", "tool_calls": [call]},
                            {"role": "tool", "tool_call_id": "call_weather", "content": "原始结果保留上下文摘要"},
                            {"role": "user", "content": batch}, {"role": "assistant", "content": "青岛今天晴。"}]
                if history[1:-1] != expected or history[-1]["role"] != "user":
                    self.send_error(422, "incorrect FC history")
                    return
                frames = [delta(content="历史配对成功")]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for frame in frames:
                self.wfile.write(("data: " + json.dumps(frame, ensure_ascii=False) + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        if self.path == "/quote/v1/chat/completions":
            history = [(m["role"], m["content"]) for m in body["messages"] if m["role"] != "system"]
            if history != [("user", "> Orbit\n\nExplain.")]:
                self.send_error(422, "unexpected quote or parent history")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"Quote received"}}]}\n\ndata: [DONE]\n\n')
            return
        gate, path = self.route()
        if path != "/v1/chat/completions" or body.get("stream") is not True:
            self.send_error(400)
            return
        gate.count += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for content, reasoning, event in [("首段", "思", gate.next_frame), ("补齐", "考", gate.finish)]:
            payload = {"choices": [{"delta": {"content": content, "reasoning_content": reasoning}}]}
            self.wfile.write(("data: " + json.dumps(payload, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()
            if not event.wait(100):
                return
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


with ThreadingHTTPServer(("127.0.0.1", 0), Reply) as server:
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
