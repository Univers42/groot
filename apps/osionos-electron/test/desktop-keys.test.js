// ADR 0039, T9: keys typed in the terminal frame reach the shell. Ctrl+R is bash's reverse search
// and Ctrl+_ readline's undo; main's reload and zoom shortcuts act only outside the terminal.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { appKeyAction } = require("../desktop-keys");

const key = (k, mods = {}) => ({ type: "keyDown", key: k, code: "", control: false, meta: false, shift: false, ...mods });
const APP = "app://osionos/index.html";
const TERMINAL = "app://terminal/index.html?theme=dark";
const table = [
  ["F5", key("F5"), "reload"],
  ["Ctrl+R", key("r", { control: true }), "reload"],
  ["Cmd+R", key("r", { meta: true }), "reload"],
  ["Ctrl+Shift+H", key("H", { control: true, shift: true }), "home"],
  ["Ctrl+=", key("=", { control: true }), "zoomIn"],
  ["Ctrl++", key("+", { control: true, shift: true }), "zoomIn"],
  ["Ctrl+-", key("-", { control: true }), "zoomOut"],
  ["Ctrl+_", key("_", { control: true, shift: true }), "zoomOut"],
  ["Ctrl+0", key("0", { control: true }), "zoomReset"],
];

describe("appKeyAction (T9)", () => {
  for (const [name, input, action] of table) {
    it(`${name}: ${action} outside the terminal, nothing inside it`, () => {
      assert.equal(appKeyAction(input, APP), action);
      assert.equal(appKeyAction(input, null), action);
      assert.equal(appKeyAction(input, TERMINAL), null);
    });
  }
  it("a key up, a plain key and an unparsable frame url are not app shortcuts, or are judged as outside", () => {
    assert.equal(appKeyAction({ ...key("F5"), type: "keyUp" }, APP), null);
    assert.equal(appKeyAction(key("r"), APP), null);
    assert.equal(appKeyAction(key("F5"), "not a url"), "reload");
  });
  it("only the terminal origin counts as the terminal", () => {
    for (const url of ["app://osionos/terminal/index.html", "https://terminal/", "app://terminal.evil/index.html"]) {
      assert.equal(appKeyAction(key("F5"), url), "reload", url);
    }
  });
});
