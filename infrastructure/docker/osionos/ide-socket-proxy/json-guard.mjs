// Duplicate-key detector for the IDE socket proxy. JSON.parse keeps the LAST of a repeated key
// while the Docker daemon (Go encoding/json) merges repeated objects field by field, so a body
// can look harmless to the vetter and still create a privileged container (K12: a second
// HostConfig carrying Privileged, Binds and PidMode, measured on docker 28.1.1). The proxy
// forwards its own re-serialization and refuses any body this finds a repeat in.
// No I/O, no deps, Node 22 builtins only.
//
// Caveat: keys compare after unescaping and case folding through upper then lower case, because
// Go matches struct fields case-insensitively. Go's fold is Unicode simple folding, so a rare
// character whose fold differs from toUpperCase().toLowerCase() could still pair two keys the
// daemon treats as one; over-folding only refuses more, and the re-serialized body carries one
// copy of each key either way. Input must already have passed JSON.parse: on syntax this scanner
// does not expect it throws, and the caller treats a throw as a refusal.

const WHITESPACE = new Set([" ", "\t", "\n", "\r"]);
const SCALAR_END = new Set([",", "]", "}", " ", "\t", "\n", "\r"]);
export const MAX_JSON_DEPTH = 64;

const foldKey = (key) => key.toUpperCase().toLowerCase();

/** The first repeated object key in `text` (as written), or null. Throws on unexpected syntax or
 *  nesting beyond MAX_JSON_DEPTH. */
export function findDuplicateKey(text) {
  let pos = 0;
  const skipSpace = () => { while (WHITESPACE.has(text[pos])) pos++; };
  const expect = (char) => {
    skipSpace();
    if (text[pos] !== char) throw new SyntaxError(`expected ${char} at ${pos}`);
    pos++;
  };

  function readString() {
    const start = pos;
    if (text[pos++] !== '"') throw new SyntaxError(`expected string at ${start}`);
    while (text[pos] !== '"') {
      if (pos >= text.length) throw new SyntaxError("unterminated string");
      pos += text[pos] === "\\" ? 2 : 1;
    }
    pos++;
    return JSON.parse(text.slice(start, pos));
  }

  function readObject(depth) {
    const seen = new Set();
    pos++;
    skipSpace();
    if (text[pos] === "}") { pos++; return null; }
    for (;;) {
      skipSpace();
      const key = readString();
      if (seen.has(foldKey(key))) return key;
      seen.add(foldKey(key));
      expect(":");
      const repeated = readValue(depth + 1);
      if (repeated !== null) return repeated;
      skipSpace();
      if (text[pos] === ",") { pos++; continue; }
      expect("}");
      return null;
    }
  }

  function readArray(depth) {
    pos++;
    skipSpace();
    if (text[pos] === "]") { pos++; return null; }
    for (;;) {
      const repeated = readValue(depth + 1);
      if (repeated !== null) return repeated;
      skipSpace();
      if (text[pos] === ",") { pos++; continue; }
      expect("]");
      return null;
    }
  }

  function readValue(depth) {
    if (depth > MAX_JSON_DEPTH) throw new RangeError("nesting too deep");
    skipSpace();
    if (text[pos] === "{") return readObject(depth);
    if (text[pos] === "[") return readArray(depth);
    if (text[pos] === '"') { readString(); return null; }
    const start = pos;
    while (pos < text.length && !SCALAR_END.has(text[pos])) pos++;
    if (pos === start) throw new SyntaxError(`expected value at ${start}`);
    return null;
  }

  const repeated = readValue(0);
  if (repeated !== null) return repeated;
  skipSpace();
  if (pos !== text.length) throw new SyntaxError("trailing data");
  return null;
}
