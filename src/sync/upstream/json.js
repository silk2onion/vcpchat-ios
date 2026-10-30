// From lioensky/VCPChat 1fadcf15, CC BY-NC-SA 4.0; browser ESM.
function parseJsonWithoutDuplicateKeys(text) {
  if (typeof text !== "string") {
    const error = new Error("JSON frame must be text");
    error.code = "PROTOCOL_INVALID";
    throw error;
  }
  let offset = 0;
  const fail = (message, code = "PROTOCOL_INVALID") => {
    const error = new Error(`${message} at byte ${offset}`);
    error.code = code;
    throw error;
  };
  const skipWhitespace = () => {
    while (/\s/.test(text[offset] || "")) offset += 1;
  };
  const scanString = () => {
    if (text[offset] !== '"') fail("expected JSON string");
    const start = offset;
    offset += 1;
    while (offset < text.length) {
      const code = text.charCodeAt(offset);
      if (code === 0x22) {
        offset += 1;
        return JSON.parse(text.slice(start, offset));
      }
      if (code < 0x20) fail("unescaped control character in JSON string");
      if (code === 0x5c) {
        offset += 1;
        const escape = text[offset];
        if (!'"\\/bfnrtu'.includes(escape || "")) {
          fail("invalid JSON escape");
        }
        if (escape === "u") {
          const hex = text.slice(offset + 1, offset + 5);
          if (!/^[a-f0-9]{4}$/i.test(hex)) fail("invalid Unicode escape");
          offset += 4;
        }
      }
      offset += 1;
    }
    fail("unterminated JSON string");
  };
  const scanValue = () => {
    skipWhitespace();
    const current = text[offset];
    if (current === "{") {
      offset += 1;
      skipWhitespace();
      const keys = new Set();
      if (text[offset] === "}") {
        offset += 1;
        return;
      }
      while (offset < text.length) {
        const key = scanString();
        if (keys.has(key)) {
          fail(`duplicate JSON object key ${JSON.stringify(key)}`, "PROTOCOL_DUPLICATE_KEY");
        }
        keys.add(key);
        skipWhitespace();
        if (text[offset] !== ":") fail("expected ':' after JSON object key");
        offset += 1;
        scanValue();
        skipWhitespace();
        if (text[offset] === "}") {
          offset += 1;
          return;
        }
        if (text[offset] !== ",") fail("expected ',' in JSON object");
        offset += 1;
        skipWhitespace();
      }
      fail("unterminated JSON object");
    }
    if (current === "[") {
      offset += 1;
      skipWhitespace();
      if (text[offset] === "]") {
        offset += 1;
        return;
      }
      while (offset < text.length) {
        scanValue();
        skipWhitespace();
        if (text[offset] === "]") {
          offset += 1;
          return;
        }
        if (text[offset] !== ",") fail("expected ',' in JSON array");
        offset += 1;
      }
      fail("unterminated JSON array");
    }
    if (current === '"') {
      scanString();
      return;
    }
    for (const literal of ["true", "false", "null"]) {
      if (text.startsWith(literal, offset)) {
        offset += literal.length;
        return;
      }
    }
    const match = text.slice(offset).match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (!match) fail("invalid JSON value");
    offset += match[0].length;
  };

  scanValue();
  skipWhitespace();
  if (offset !== text.length) fail("unexpected trailing JSON data");
  return JSON.parse(text);
}


export { parseJsonWithoutDuplicateKeys };
