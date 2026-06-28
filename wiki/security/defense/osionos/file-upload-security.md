# File Upload Security — osionos (the block editor)

> Every chat attachment is validated against an executable extension denylist, per-kind byte caps, and client-side image re-encoding before a single byte is sent over the bridge socket.

## What it is (the concept)

**File upload security** is the practice of restricting which files a user may upload to a system, based on **MIME type classification**, **file extension allowlisting/denylisting**, and **size limits** enforced at intake. Without these controls an upload endpoint becomes a conduit for **malware distribution** (delivering executable payloads disguised as attachments) and **resource exhaustion** (oversized files that crash stateful transports). A **defense-in-depth** posture layers client-side gates (fast UX rejection, socket protection) with server-side authority (the canonical enforcement layer).

## What it defends against

See [Unrestricted File Upload](../../attack/file-upload-security.md).

In the osionos context, the chat attachment flow is the specific attack surface: a malicious workspace member could attempt to upload a `.exe`, `.sh`, or `.deb` payload through the channel message composer, relying on recipients treating the filename as trustworthy. Separately, an oversized file (the code comments an uncapped upload would "reset the bridge socket") would sever the persistent WebSocket connection shared by all active editors in that workspace.

## How osionos implements it

All validation logic is centralised in [`apps/osionos/app/src/shared/chat/mediaProcessing.ts`](../../../../apps/osionos/app/src/shared/chat/mediaProcessing.ts). It exposes three layered controls:

**1. Executable extension denylist (`BLOCKED_EXT`)**

```ts
// mediaProcessing.ts, lines 37-39
const BLOCKED_EXT = new Set([
  'exe', 'bat', 'cmd', 'com', 'msi', 'scr', 'sh', 'bash', 'zsh', 'ps1', 'jar', 'app', 'dmg', 'deb', 'rpm',
]);
```

The set covers Windows PE executables, shell interpreters across all platforms, Java archives, and common Linux/macOS package formats. A file whose MIME type resolves to `'file'` (the generic fallback) and whose extension matches an entry is rejected with a user-facing error before any network call.

**2. Per-kind byte caps (`MEDIA_LIMITS`)**

```ts
// mediaProcessing.ts, lines 25-30
export const MEDIA_LIMITS = {
  image: 25 * MB,
  video: 50 * MB,
  audio: 16 * MB,
  file: 50 * MB,
} as const;
```

`mediaKindOf()` classifies the file by its MIME prefix (`image/`, `video/`, `audio/`, or the `'file'` fallback); `validateFile()` then checks `file.size > MEDIA_LIMITS[kind]` and returns a typed `{ ok: false; error: string }` on breach. The error message includes the actual file size (formatted via `formatBytes()`) and the applicable cap, making the rejection actionable for the end user.

**3. Image re-encoding before upload (`compressImage()`)**

Images are passed through `compressImage()` before the upload call. Frames wider or taller than 1920 px are downscaled; the result is re-encoded to WebP at quality 0.82 via `canvas.toBlob`. A file is passed through unchanged only when the re-encoded blob would be *larger* than the original or when the source is an animated GIF (which `canvas.toBlob` would strip to a single frame). The re-encoding step serves two purposes: it reduces bridge payload size substantially (a 4K PNG described in the module docstring as ">25 MB lossless" becomes approximately 1 MB) and it strips any metadata or embedded payloads in the image container.

The gate point is [`apps/osionos/app/src/widgets/channel-messages/model/useAttachmentUpload.ts`](../../../../apps/osionos/app/src/widgets/channel-messages/model/useAttachmentUpload.ts). The `upload()` callback calls `validateFile(file)` as its **first statement**, before any compression or network operation:

```ts
// useAttachmentUpload.ts, lines 42-46
const check = validateFile(file);
if (!check.ok) {
  useToastStore.getState().push({ kind: 'error', title: 'Can't attach file', description: check.error });
  return null;
}
```

A rejection here returns `null` immediately; `uploadAttachment` is never invoked.

## How we know it is applied

The attachment hook `useAttachmentUpload` is wired directly into the channel message composer. The code path is unconditional: `validateFile` is not behind a feature flag and has no bypass branch. Any file selected through the composer's file picker must pass through this hook — there is no alternate code path that reaches `uploadAttachment` without calling `validateFile` first.

The live guard can be confirmed by inspecting the hook's single export:

```ts
// useAttachmentUpload.ts, lines 40-45
const upload = useCallback(
  async (file: File): Promise<Attachment | null> => {
    const check = validateFile(file);
    if (!check.ok) { ... return null; }
    // compression and upload follow only after this point
```

This is client-side enforcement and is therefore a **defense-in-depth** layer. The authoritative upload boundary is the bridge (`apps/osionos/app/scripts/bridge-api.mjs`, `VITE_API_URL=https://localhost:4000`) and the server-side API route that receives the multipart payload — those layers carry the canonical enforcement.

## Reference

The [OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html) specifies the full taxonomy of controls expected on both client and server: extension validation, MIME verification, size limits, file renaming, and storage isolation. The osionos client-side implementation covers the extension denylist, size capping, and a form of content normalisation (re-encoding to WebP); the cheat sheet frames these as necessary but insufficient without the corresponding server-side layer.

## Residual risk / assumptions

- **Client-side only**: The `validateFile` and `compressImage` controls run entirely in the browser. A determined attacker who bypasses the UI (e.g. via a direct HTTP request to the bridge upload endpoint) faces no resistance from this layer. Server-side MIME inspection and size enforcement on the bridge are the authoritative gate.
- **Extension check, not magic-byte check**: The denylist operates on `file.name.split('.').pop().toLowerCase()`. A file named `malware.txt` with PE bytes is not caught here; the extension check guards against accidental delivery of clearly-labelled executables, not adversarially renamed files.
- **MIME classification is browser-supplied**: `mediaKindOf()` reads `file.type`, which the browser populates from its own MIME sniffing of the local file. A browser that misclassifies a file type could cause a different size cap to apply, or cause an executable `file`-kind check to be skipped if the MIME is misidentified as `image/`.
- **Animated GIF bypass of re-encoding**: Animated GIFs are explicitly passed through `compressImage()` untouched. Additionally, if the browser does not implement `createImageBitmap`, the function returns the original file for **all** image types — not just GIFs. The actual guard is `if (file.type === 'image/gif' || typeof createImageBitmap !== 'function') return { file };` (line 76). In any environment where `createImageBitmap` is absent, no image is compressed or metadata-stripped, regardless of format. Any payload embedded in a valid GIF container, or any image uploaded from a browser lacking `createImageBitmap`, is not stripped.
- **No content-address or virus scan**: There is no client-side antivirus call, hash-based blocklist, or content-scanning hook. Detection of novel malware disguised as allowed file types is entirely outside scope of this control.
