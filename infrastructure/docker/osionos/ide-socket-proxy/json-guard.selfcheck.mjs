// Cases for json-guard.mjs. Run from the worktree root, no daemon needed:
//   node infrastructure/docker/osionos/ide-socket-proxy/json-guard.selfcheck.mjs

import { fileURLToPath } from "node:url";
import { findDuplicateKey } from "./json-guard.mjs";

const DUPLICATES = [
  ["top-level key twice", '{"Image":"a","Image":"b"}', "Image"],
  ["HostConfig twice, benign last", '{"HostConfig":{"Privileged":true},"HostConfig":{"CapDrop":["ALL"]}}', "HostConfig"],
  ["Privileged twice inside HostConfig", '{"HostConfig":{"Privileged":true,"Privileged":false}}', "Privileged"],
  ["repeat inside an array element", '{"Mounts":[{"Type":"volume","Type":"bind"}]}', "Type"],
  ["escaped spelling of the same key", '{"HostConfig":{},"Host\\u0043onfig":{}}', "HostConfig"],
  ["other case of the same key", '{"HostConfig":{},"hostconfig":{}}', "hostconfig"],
  ["repeat after whitespace and a nested value", '{ "a" : [ 1 , { "b" : null } ] ,\n"a" : 2 }', "a"],
  ["key with an escaped quote repeated", '{"a\\"b":1,"a\\"b":2}', 'a"b'],
];

const CLEAN = [
  ["empty object", "{}"],
  ["same key in sibling objects", '{"a":{"x":1},"b":{"x":2}}'],
  ["same key in sibling array elements", '[{"x":1},{"x":2}]'],
  ["scalars and strings holding braces", '{"a":"{\\"a\\":1}","b":[1,-2.5e3,true,false,null,"]"]}'],
  ["nested depth within the cap", `${'{"a":'.repeat(60)}1${"}".repeat(60)}`],
];

const MALFORMED = [
  ["trailing data", '{"a":1} x'],
  ["missing colon", '{"a" 1}'],
  ["unterminated string", '{"a'],
  ["nesting beyond the cap", `${"[".repeat(200)}${"]".repeat(200)}`],
];

export function guardFailures() {
  const fail = [];
  for (const [label, text, want] of DUPLICATES) {
    let got;
    try { got = findDuplicateKey(text); } catch (error) { got = `threw ${error.message}`; }
    if (got !== want) fail.push(`${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  }
  for (const [label, text] of CLEAN) {
    let got;
    try { got = findDuplicateKey(text); } catch (error) { got = `threw ${error.message}`; }
    if (got !== null) fail.push(`${label}: got ${JSON.stringify(got)}, want null`);
  }
  for (const [label, text] of MALFORMED) {
    try { findDuplicateKey(text); fail.push(`${label}: accepted, want a throw`); } catch { /* refusal */ }
  }
  return fail;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const fail = guardFailures();
  if (fail.length) { process.stderr.write(`json-guard selfcheck FAIL:\n${fail.join("\n")}\n`); process.exit(1); }
  process.stdout.write("json-guard selfcheck OK: every repeated key found, clean bodies pass\n");
}
