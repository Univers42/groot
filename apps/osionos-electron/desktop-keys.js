"use strict";
// main's own shortcuts: reload, back to the app home, zoom. ADR 0039 (T9): when the terminal
// frame has focus they belong to the shell (Ctrl+R is bash's reverse search, Ctrl+_ readline's
// undo, and a reload would kill every shell). Pure, so `node --test` runs it without Electron.

// Node's URL gives a custom scheme the origin "null", so the origin is compared by its parts.
function isTerminalFrameUrl(url) {
  try {
    const u = new URL(url);
    return u.protocol === "app:" && u.host === "terminal";
  } catch {
    return false;
  }
}

function appKeyAction(input, focusedFrameUrl) {
  if (input.type !== "keyDown" || isTerminalFrameUrl(focusedFrameUrl)) return null;
  const withModifier = input.control || input.meta;
  if (input.key === "F5" || (withModifier && /^r$/i.test(input.key))) return "reload";
  if (withModifier && input.shift && /^h$/i.test(input.key)) return "home";
  if (!withModifier) return null;
  if (input.key === "=" || input.key === "+" || input.code === "Equal" || input.code === "NumpadAdd") return "zoomIn";
  if (input.key === "-" || input.key === "_" || input.code === "Minus" || input.code === "NumpadSubtract") return "zoomOut";
  if (input.key === "0") return "zoomReset";
  return null;
}

module.exports = { appKeyAction };
