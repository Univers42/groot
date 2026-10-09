#!/usr/bin/env node
// Extracts the <graph-studio> host contract that osionos relies on from a graph_render source tree,
// as JSON on stdout. Every leaf is { value, at: "path:line" } so a reviewer can check it by eye.
//
//   node extract.mjs --git <graph_render clone> --rev <sha>    read the tree through git
//   node extract.mjs --tree <dir> --rev <label>                read a checked-out tree
//   --lenient   record a rule that matches nothing as "MISSING" and exit 3 (the drift report)
//
// Each rule searches every non-test source file in SCOPE rather than a fixed path, so a file that
// moves upstream is still found; a rule that matches the wrong number of lines exits 2 (strict).
// Ponytail: these are line regexes over TypeScript/Rust text, not a parser. They miss a contract
// that is spelled differently (a member renamed, a list split across lines it did not use before)
// and report that as MISSING/exit 2, never as a silently different value; the fix is to adjust the
// rule here and regenerate, and the diff then shows what moved.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SCOPE = ["packages/graph-studio/src", "crates/graph-sdk-js/src", "crates/graph-wasm/src/lib.rs"];
const TEST = /(^|\/)(tests?|__tests__)\/|\.(test|spec)\.[cm]?[jt]sx?$/;
const SOURCE = /\.(ts|tsx|rs)$/;
/** A comment line never counts as a match: prose may quote the code it describes. */
const COMMENT = /^\s*(\/\/|\/\*|\*)/;

function args(argv) {
  const out = { lenient: false };
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (flag === "--lenient") out.lenient = true;
    else if (["--git", "--tree", "--rev"].includes(flag)) out[flag.slice(2)] = argv[(i += 1)];
    else throw new Error(`unknown argument ${flag}`);
  }
  if ((out.git === undefined) === (out.tree === undefined) || out.rev === undefined) {
    throw new Error("usage: extract.mjs (--git <dir> | --tree <dir>) --rev <rev> [--lenient]");
  }
  return out;
}

function walk(root, dir, files) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(root, path, files);
    else files.push(relative(root, path));
  }
  return files;
}

function sourceOf(opts) {
  if (opts.git !== undefined) {
    const git = (...a) => execFileSync("git", ["-C", opts.git, ...a], { encoding: "utf8", maxBuffer: 64 << 20 });
    const rev = git("rev-parse", "--verify", `${opts.rev}^{commit}`).trim();
    const paths = git("ls-tree", "-r", "--name-only", rev, "--", ...SCOPE).split("\n").filter(Boolean);
    return { rev, paths, read: (path) => git("show", `${rev}:${path}`) };
  }
  const paths = SCOPE.flatMap((p) => {
    const full = join(opts.tree, p);
    try {
      return statSync(full).isDirectory() ? walk(opts.tree, full, []) : [p];
    } catch {
      return [];
    }
  });
  return { rev: opts.rev, paths, read: (path) => readFileSync(join(opts.tree, path), "utf8") };
}

/**
 * The lines a rule is matched against, cited by their first physical line: comments dropped, and a
 * call whose arguments a formatter wrapped (`f(` … `);`) joined back into one line, so a reflow
 * upstream reads as the same code rather than as a missing rule.
 */
function logicalLines(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i += 1) {
    if (COMMENT.test(lines[i])) continue;
    let text = lines[i];
    const line = i + 1;
    if (/\($/.test(text)) {
      let j = i + 1;
      while (j < lines.length && !/^\s*\)[;,]?$/.test(lines[j]) && j - i < 8) j += 1;
      if (j < lines.length && j - i < 8) {
        text = `${text}${lines.slice(i + 1, j).map((l) => l.trim()).join(" ")}${lines[j].trim()}`.replace(/,\)/, ")");
        i = j;
      }
    }
    out.push({ text, line });
  }
  return out;
}

const opts = args(process.argv.slice(2));
const src = sourceOf(opts);
const files = src.paths
  .filter((p) => SOURCE.test(p) && !TEST.test(p))
  .sort()
  .map((path) => {
    const lines = src.read(path).split("\n");
    return { path, lines, logical: logicalLines(lines) };
  });
const missing = [];

class Missing extends Error {}

function fail(rule, found) {
  const why = `${rule}: expected exactly one match, found ${found.length}${found.length ? ` (${found.map((f) => f.at).join(", ")})` : ""}`;
  if (!opts.lenient) {
    process.stderr.write(`extract.mjs: ${why}\n`);
    process.exit(2);
  }
  missing.push(why);
  throw new Missing(why);
}

/** Every line in scope (optionally only files whose path matches `only`) that `re` matches. */
function all(re, only = /./) {
  const found = [];
  for (const file of files) {
    if (!only.test(file.path)) continue;
    for (const { text, line } of file.logical) {
      const hits = re.global ? [...text.matchAll(re)] : [text.match(re)].filter(Boolean);
      for (const m of hits) found.push({ m, path: file.path, line, at: `${file.path}:${line}` });
    }
  }
  return found;
}

function one(re, only) {
  const found = all(re, only);
  if (found.length !== 1) fail(String(re), found);
  return found[0];
}

/** The lines from the one match of `start` up to the first line after it matching `end`. */
function block(start, end, only) {
  const head = one(start, only);
  const lines = files.find((f) => f.path === head.path).lines;
  for (let i = head.line; i < lines.length; i += 1) {
    if (end.test(lines[i])) {
      return { path: head.path, from: head.line, to: i + 1, at: `${head.path}:${head.line}-${i + 1}`, body: lines.slice(head.line, i).map((text, k) => ({ text, line: head.line + 1 + k })) };
    }
  }
  return fail(`${start} … ${end}`, []);
}

const strings = (text) => [...text.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
const leaf = (value, at) => ({ value, at });
const lenient = (fn) => {
  try {
    return fn();
  } catch (error) {
    if (error instanceof Missing) return "MISSING";
    throw error;
  }
};

/** `interface X { readonly a: T; b(x): U; }` → { a: {value: "readonly a: T", at}, … }, comments skipped. */
function members(name) {
  const b = block(new RegExp(`^export interface ${name}\\b.*\\{$`), /^\}$/);
  const out = {};
  for (const { text, line } of b.body) {
    const m = text.match(/^\s+(?:readonly\s+)?(\w+)(\??)(\(.*\))?:\s.*;$/);
    if (m) out[m[1]] = leaf(text.trim().replace(/;$/, ""), `${b.path}:${line}`);
  }
  return out;
}

/** The defaults `readNode`/`readEdge` fill, from the object they return. */
function defaults(fn) {
  const b = block(new RegExp(`function ${fn}\\(`), /^\}$/);
  const out = {};
  for (const { text, line } of b.body) {
    const m = text.match(/^\s+(\w+): (.+),$/);
    if (!m || /^(source|target)$/.test(m[1]) && !m[2].includes("value.")) continue;
    out[m[1]] = leaf(defaultOf(m[2]), `${b.path}:${line}`);
  }
  return { range: b, out };
}

function defaultOf(expr) {
  let m = expr.match(/^optional(?:String|Number|Boolean)\(value\.\w+(?:, (.+))?\)(?: \?\? (.+))?$/);
  if (m) {
    const raw = m[1] ?? m[2];
    if (raw === undefined) return null;
    if (/^-?\d+(\.\d+)?$/.test(raw)) return Number(raw);
    if (/^"[^"]*"$/.test(raw)) return raw.slice(1, -1);
    if (raw === "true" || raw === "false") return raw === "true";
    return `= ${raw}`;
  }
  if ((m = expr.match(/^stringList\(value\.\w+\)$/))) return [];
  return `= ${expr}`;
}

const ingestFiles = /packages\/graph-studio\/src\/source\/ingest[^/]*\.ts$/;

function element() {
  const def = one(/^export function defineGraphStudio\(.*\btag = "([^"]+)"/);
  const entry = files.find((f) => f.path === def.path);
  const exports = [];
  entry.lines.forEach((text, i) => {
    const at = `${def.path}:${i + 1}`;
    let m;
    if ((m = text.match(/^export \{ ([^}]+) \} from/))) for (const n of m[1].split(",")) exports.push(leaf(n.trim(), at));
    else if ((m = text.match(/^export (?:async )?(?:function|const|class) (\w+)/))) exports.push(leaf(m[1], at));
  });
  exports.sort((a, b) => a.value.localeCompare(b.value));
  const connect = one(/^\s+connectedCallback\(\): void \{$/);
  const observed = all(/observedAttributes|attributeChangedCallback/);
  const attributes = {};
  const base = one(/new URL\(host\.getAttribute\(name\) \?\? fallback, ([\w.]+)\)/);
  for (const a of all(/absolute\("([a-z-]+)", "([^"]+)"\)/g)) {
    attributes[a.m[1]] = leaf({ kind: "url", default: a.m[2], resolved_against: base.m[1] }, `${a.at} ${base.at}`);
  }
  for (const a of all(/host\.getAttribute\("([a-z-]+)"\) === "([^"]+)"/)) attributes[a.m[1]] = leaf({ kind: "enum", on_when: a.m[2] }, a.at);
  const flags = {};
  for (const a of all(/host\.hasAttribute\("([a-z-]+)"\)/)) (flags[a.m[1]] ??= []).push(a.at);
  for (const [name, ats] of Object.entries(flags)) attributes[name] = leaf({ kind: "presence" }, ats.join(" "));
  return {
    tag: leaf(def.m[1], def.at),
    define: leaf("defineGraphStudio(options?, tag?) — the pack does not define the element on import", def.at),
    entry_exports: exports,
    observed_attributes: leaf(observed.map((o) => o.m[0]), observed.length ? observed.map((o) => o.at).join(" ") : `none in scope; attributes are read once in ${connect.at}`),
    attributes: Object.fromEntries(Object.entries(attributes).sort(([a], [b]) => a.localeCompare(b))),
  };
}

function versions() {
  const host = one(/^export const HOST_API = (\d+);/);
  const wasm = one(/^pub const ABI_VERSION: u32 = (\d+);/, /crates\/graph-wasm\//);
  const sdk = one(/^export const ABI_VERSION = (\d+);/, /crates\/graph-sdk-js\//);
  const vias = one(/^export const OPEN_VIAS = \[([^\]]*)\] as const;/);
  return {
    host_api: leaf(Number(host.m[1]), host.at),
    abi_version_wasm: leaf(Number(wasm.m[1]), wasm.at),
    abi_version_sdk: leaf(Number(sdk.m[1]), sdk.at),
    open_vias: leaf(strings(vias.m[1]), vias.at),
  };
}

function events() {
  const b = block(/^export interface HostEvents \{$/, /^\}$/);
  const detail = {};
  for (const { text, line } of b.body) {
    const m = text.match(/^\s+readonly "([a-z-]+)": (.+);$/);
    if (m) detail[m[1]] = leaf(m[2], `${b.path}:${line}`);
  }
  const init = one(/new CustomEvent\(name, \{.*bubbles: (true|false), composed: (true|false)/);
  const sites = {};
  for (const s of all(/\bemit\([\w.]+, "([a-z-]+)"/)) (sites[s.m[1]] ??= []).push(s.at);
  return {
    detail,
    init: leaf({ bubbles: init.m[1] === "true", composed: init.m[2] === "true", detail: "structuredClone, deep-frozen" }, init.at),
    dispatched_from: Object.fromEntries(Object.entries(sites).sort(([a], [b]) => a.localeCompare(b)).map(([n, ats]) => [n, leaf(ats.length, ats.join(" "))])),
  };
}

function refusal() {
  const naming = one(/^const INGEST_REFUSAL = "(\w+)";/);
  const wire = one(/^\s+return shown\.code \?\? shown\.title;$/);
  return {
    load_graph_rejection_name: leaf(naming.m[1], naming.at),
    graph_error_detail_error: leaf("ShownError.code ?? ShownError.title — equals the rejection's name", wire.at),
  };
}

function ingest() {
  const dup = one(/throw new (\w+)\(source, `duplicate node id /, ingestFiles);
  const cls = dup.m[1];
  const name = one(new RegExp(`^\\s+this\\.name = "(${cls})";$`), ingestFiles);
  const prefix = one(new RegExp(`^\\s+super\\((\`\\$\\{source\\}: \\$\\{message\\}\`)\\);$`), ingestFiles);
  const version = one(new RegExp(`if \\(version !== (\\d+)\\) throw new ${cls}`), ingestFiles);
  const assumed = one(/no `version` member: assumed (\d+)/, ingestFiles);
  const nk = one(/^export const NODE_KINDS: readonly NodeKind\[\] = \[(.*)\];$/, ingestFiles);
  const ek = one(/^export const EDGE_KINDS: readonly EdgeKind\[\] = \[(.*)\];$/, ingestFiles);
  const wireNode = block(/^const CONTRACT_MEMBERS = \[$/, /^\] as const;$/, ingestFiles);
  const extra = one(/^const NODE_MEMBERS = \[\.\.\.CONTRACT_MEMBERS, (.*)\] as const;$/, ingestFiles);
  const edge = block(/^const EDGE_MEMBERS = \[$/, /^\] as const;$/, ingestFiles);
  const alias = one(/\[\.\.\.EDGE_MEMBERS, "(\w+)"\]/, ingestFiles);
  const spell = one(/return wireType\.includes\("(\w+)"\) \|\| wireType === "(\w+)" \|\| wireType === "(\w+)";|if \(wireType\.includes\("(\w+)"\) \|\| wireType === "(\w+)" \|\| wireType === "(\w+)"\)/, ingestFiles);
  const sp = spell.m.slice(1).filter(Boolean);
  const nodeKind = one(/^\s+if \(value === undefined\) return "(\w+)";$/, ingestFiles);
  const edgeKindFn = block(/function edgeKindOf\(/, /^\}$/, ingestFiles);
  const edgeKind = edgeKindFn.body.filter((l) => /^\s+return "\w+";$/.test(l.text)).at(-1);
  if (edgeKind === undefined) fail("edgeKindOf: the default `return \"kind\";`", []);
  const nodes = defaults("readNode");
  const edges = defaults("readEdge");
  const inside = (r, s) => s.path === r.path && s.line > r.from && s.line < r.to;
  const required = { node: [], edge: [] };
  for (const s of all(/requireString\(source, at, value, "(\w+)"\)/, ingestFiles)) {
    if (inside(nodes.range, s)) required.node.push(leaf(s.m[1], s.at));
    else if (inside(edges.range, s)) required.edge.push(leaf(s.m[1], s.at));
  }
  // A literal message is kept as its text; anything else (a ternary, a call) as its expression.
  // Sorted: the order is the files' and not part of the contract.
  const templates = all(new RegExp(`throw new ${cls}\\(source, (.+)\\);$`), ingestFiles).map((t) => {
    const lit = t.m[1].match(/^(?:`((?:\\`|[^`])*)`|"([^"]*)")$/);
    return leaf(lit ? (lit[1]?.replaceAll("\\`", "`") ?? lit[2]) : `= ${t.m[1]}`, t.at);
   }).sort((a, b) => a.value.localeCompare(b.value));
  const pick = (re) => {
    const hits = templates.filter((t) => re.test(t.value));
    if (hits.length !== 1) fail(`refusal ${re}`, hits);
    return hits[0];
  };
  const cap = one(/^export const MAX_DOCUMENT_CHARS = (.+);/);
  return {
    refusal_class: leaf(name.m[1], name.at),
    refusal_message: leaf(prefix.m[1], prefix.at),
    doc_version: leaf(Number(version.m[1]), version.at),
    doc_version_when_absent: leaf(Number(assumed.m[1]), assumed.at),
    node_kinds: leaf(strings(nk.m[1]), nk.at),
    edge_kinds: leaf(strings(ek.m[1]), ek.at),
    node_wire_members: leaf(wireNode.body.flatMap((l) => strings(l.text)), wireNode.at),
    node_extra_members: leaf(strings(extra.m[1]), extra.at),
    edge_members: leaf(edge.body.flatMap((l) => strings(l.text)), edge.at),
    edge_accepted_alias: leaf(alias.m[1], alias.at),
    hierarchy_type_spellings: leaf({ contains: sp[0], equals: sp.slice(1), case: "lowercased before the test" }, spell.at),
    required_strings: required,
    node_defaults: { kind: leaf(nodeKind.m[1], nodeKind.at), ...nodes.out },
    edge_defaults: { kind: leaf(edgeKind.text.match(/"(\w+)"/)[1], `${edgeKindFn.path}:${edgeKind.line}`), ...edges.out },
    refuse_duplicate_node_id: pick(/^duplicate node id /),
    refuse_duplicate_edge_id: pick(/^duplicate edge id /),
    refuse_dangling_endpoint: pick(/which is not a node$/),
    refusals: templates,
    max_document_chars: leaf(cap.m[1], cap.at),
  };
}

const contract = {
  about: "Generated by tests/graph-studio-contract/extract.mjs from graph_render at source_rev. Do not edit: regenerate.",
  source_rev: src.rev,
  element: lenient(element),
  versions: lenient(versions),
  host_members: lenient(() => members("GraphStudioHost")),
  load_result: lenient(() => members("LoadResult")),
  node_preview: lenient(() => members("NodePreview")),
  events: lenient(events),
  rejection: lenient(refusal),
  ingest: lenient(ingest),
};
if (missing.length) contract.missing = missing;
process.stdout.write(`${JSON.stringify(contract, null, 2)}\n`);
process.exit(missing.length ? 3 : 0);
