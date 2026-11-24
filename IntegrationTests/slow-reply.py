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
