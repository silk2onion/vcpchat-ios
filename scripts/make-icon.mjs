import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const size = 1024;
const pixels = Buffer.alloc(size * size * 4);
for (let y = 0; y < size; y += 1) {
  for (let x = 0; x < size; x += 1) {
    const index = (y * size + x) * 4;
    const dx = x - 512;
    const dy = y - 512;
    const outside = Math.max(Math.abs(dx), Math.abs(dy)) > 430;
    const onV = x > 250 && x < 774 && y > 230 && y < 790 && (Math.abs(x - 512) * 0.72 < y - 250) && (Math.abs(x - 512) * 0.72 > y - 470);
    const ink = outside ? [22, 19, 15, 0] : onV ? [226, 161, 90, 255] : [22, 19, 15, 255];
    pixels[index] = ink[0];
    pixels[index + 1] = ink[1];
    pixels[index + 2] = ink[2];
    pixels[index + 3] = ink[3];
  }
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(body));
  return Buffer.concat([length, body, checksum]);
}

const raw = Buffer.alloc((size * 4 + 1) * size);
for (let y = 0; y < size; y += 1) {
  raw[y * (size * 4 + 1)] = 0;
  pixels.copy(raw, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(size, 0);
ihdr.writeUInt32BE(size, 4);
ihdr[8] = 8;
ihdr[9] = 6;
const png = Buffer.concat([
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(raw)),
  chunk("IEND", Buffer.alloc(0)),
]);
const output = path.resolve("src-tauri/app-icon.png");
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, png);
console.log(output);
