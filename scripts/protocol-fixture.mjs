// Deterministic loopback-only VCP protocol fixture. Dummy keys; never uses live credentials.
import http from 'node:http';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
const server = http.createServer(async (req, res) => {
  if (req.headers.authorization !== 'Bearer fixture-chat') { res.writeHead(401).end(); return; }
  if (req.url === '/v1/models') {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({ data: Array.from({ length: 350 }, (_, i) => ({ id: `fixture-${i}` })) })); return;
  }
  if (req.url !== '/v1/chat/completions') { res.writeHead(404).end(); return; }
  const chunks = []; for await (const chunk of req) chunks.push(chunk);
  const body = JSON.parse(Buffer.concat(chunks));
  if (!body.stream || !body.messages?.length) { res.writeHead(400).end(); return; }
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
  const event = text => `data: ${JSON.stringify({ choices: [{ delta: { content: text } }] })}\n\n`;
  if (body.model === 'abrupt') { res.end(event('部分内容保留')); return; }
  if (body.model === 'slow') {
    let n = 0; const timer = setInterval(() => { res.write(event(`片段${++n} `)); if (n >= 100) { clearInterval(timer); res.end('data: [DONE]\n\n'); } }, 12);
    res.on('close', () => clearInterval(timer)); return;
  }
  res.write(': heartbeat\r\n\r\n' + event('字').repeat(500));
  const tail = Buffer.from(event('🌸尾巴') + 'data: [DONE]\n\n');
  const split = tail.indexOf(Buffer.from('🌸')) + 2; // Split in the middle of a 4-byte scalar.
  res.write(tail.subarray(0, split)); setTimeout(() => res.end(tail.subarray(split)), 24);
});
function send(socket, payload) {
  const b = Buffer.from(JSON.stringify(payload));
  socket.write(Buffer.concat([Buffer.from([0x81, b.length]), b]));
}
server.on('upgrade', (req, socket) => {
  if (!req.url.startsWith('/VCPlog/VCP_Key=fixture-log?')) { socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); return; }
  const accept = createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  send(socket, { type: 'pre_ack', message: 'must not report connected yet' });
  setTimeout(() => send(socket, { type: 'connection_ack', message: 'authenticated' }), 15);
  setTimeout(() => send(socket, { type: 'vcp_log', message: 'native fixture log' }), 25);
  socket.on('error', () => {}); socket.on('data', () => {});
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], `http://127.0.0.1:${server.address().port}`));
