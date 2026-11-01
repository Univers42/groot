// A module main.js or pty-host.js requires but the builder's "files" leaves out is missing from the
// installed app, which then fails at launch. Both builder configs must ship every local module.
// Caveat: reads require("./x") calls by regex; a require built from a variable is not seen.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
function localModules(entry, seen = new Set()) {
  if (seen.has(entry)) return seen;
  seen.add(entry);
  const source = fs.readFileSync(path.join(root, entry), "utf8");
  for (const [, name] of source.matchAll(/require\("\.\/([\w.-]+)"\)/g)) localModules(name.endsWith(".js") ? name : name + ".js", seen);
  return seen;
}
const shipped = [...localModules("main.js"), ...localModules("pty-host.js"), "preload.js"];

describe("packaged files", () => {
  const configs = {
    "package.json build.files": JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).build.files,
    "electron-builder.native.json files": JSON.parse(fs.readFileSync(path.join(root, "electron-builder.native.json"), "utf8")).files,
  };
  for (const [name, files] of Object.entries(configs)) {
    it(`${name} ships every local module`, () => {
      assert.deepEqual(shipped.filter((f) => !files.includes(f)), []);
    });
  }
});
