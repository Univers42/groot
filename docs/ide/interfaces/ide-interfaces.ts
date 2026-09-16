/**
 * Phase 1 interface definitions for the osionos IDE surface (ADR-001/002/003).
 * Spec artifact: standalone-compilable, no runtime imports. These types move into
 * `apps/osionos/app/src/features/ide/` in Phase 2; consumers may only depend on
 * what is declared here — anything a provider needs beyond this is a leak.
 */

/* ────────────────────────── ADR-001 · VFS ────────────────────────── */

/** Opaque path. Constructed ONCE at the boundary; consumers never string-join. */
export type VPath = {
  /** Full URI, e.g. "sandbox://<workspaceId>/workspace/src/main.c". */
  readonly uri: string;
  /** Scheme = provider key in the mount table ("osionos" | "sandbox" | "mem" | "overlay" | …). */
  readonly scheme: string;
  /** Mount authority (workspace id for osionos:// and sandbox://). */
  readonly authority: string;
  /** Normalized segments — ".."/"." resolved (never escaping the mount root), original bytes preserved. */
  readonly segments: readonly string[];
  /** NFC-normalized comparison key (equality/collision checks; never round-tripped to providers). */
  readonly compareKey: string;
};

export type FsErrorCode =
  | "NotFound" | "PermissionDenied" | "NotADirectory" | "IsADirectory"
  | "NotEmpty" | "AlreadyExists" | "Loop" | "NoSpace" | "ReadOnly"
  | "TooLarge" | "Interrupted" | "Unsupported" | "Io";

export type FsError = { code: FsErrorCode; path?: VPath; detail?: string };

export type FsEntryKind = "file" | "dir" | "symlink" | "other";

export type FsStat = {
  kind: FsEntryKind;
  sizeBytes: number;
  mtimeMs: number | null;      // null when the backend cannot report it
  readonly readOnly: boolean;
  target?: string;             // symlink target, provider-native form
};

export type FsCapabilities = {
  caseSensitivity: "sensitive" | "insensitive-preserving" | "insensitive";
  symlinks: boolean;
  hardlinks: boolean;
  atomicRename: boolean;
  /** "none" providers still satisfy watch() — it completes immediately and the
   *  consumer must poll; pollIntervalMs is the provider's honest suggestion. */
  watch: "native" | "poll" | "none";
  pollIntervalMs?: number;
  maxNameBytes: number;
  maxPathBytes: number;
  unicodeForm: "nfc" | "nfd" | "opaque-bytes";
  streamingReads: boolean;
  permissionsModel: "posix" | "readonly" | "none";
  sparse: boolean;
  xattrs: boolean;
};

export type WatchEvent = {
  type: "create" | "write" | "delete" | "rename";
  path: VPath;
  renamedFrom?: VPath;
  /** Coalesced event count folded into this one (≥1). */
  coalesced: number;
};

export type ReadOptions = { offset?: number; length?: number; signal?: AbortSignal };
export type WriteOptions = { create?: boolean; overwrite?: boolean; signal?: AbortSignal };
export type ListedEntry = { name: string; kind: FsEntryKind };

/** The whole provider contract. Adding a backend = implementing this, nothing else. */
export interface FsProvider {
  readonly scheme: string;
  capabilities(): FsCapabilities;
  stat(path: VPath, signal?: AbortSignal): Promise<FsStat>;
  list(path: VPath, signal?: AbortSignal): Promise<ListedEntry[]>;
  /** Ranged, streaming. A 4 GB file must never be materialized to satisfy this call. */
  read(path: VPath, opts?: ReadOptions): Promise<ReadableStream<Uint8Array>>;
  write(path: VPath, data: ReadableStream<Uint8Array> | Uint8Array, opts?: WriteOptions): Promise<void>;
  mkdir(path: VPath, signal?: AbortSignal): Promise<void>;
  delete(path: VPath, opts?: { recursive?: boolean; signal?: AbortSignal }): Promise<void>;
  rename(from: VPath, to: VPath, opts?: { overwrite?: boolean; signal?: AbortSignal }): Promise<void>;
  /** Long-lived; ends on signal abort. Events are coalesced per capabilities(). */
  watch(path: VPath, onEvent: (e: WatchEvent) => void, signal: AbortSignal): Promise<void>;
  close(): Promise<void>;
}

export interface MountTable {
  resolve(uri: string): { provider: FsProvider; path: VPath };
  mounts(): ReadonlyArray<{ scheme: string; authority: string; provider: FsProvider }>;
}

/** ADR-001 §7 — the explicit replacement for implicit hybrid sync. */
export type SyncConflict = { path: VPath; leftHash: string; rightHash: string; atMs: number };
export type SyncLinkPolicy = {
  direction: "bidirectional" | "leftToRight" | "rightToLeft";
  maxFileBytes: number;                 // v1: 512 * 1024
  ignore: readonly string[];            // glob list (node_modules, .git, …)
  binary: "skip" | "sync";
  onConflict: (c: SyncConflict) => void; // surfaced, never silent LWW
};

/* ───────────────────────── ADR-002 · Terminal ───────────────────────── */

export type PtyCapabilities = {
  resize: boolean;
  signals: "tty-line-discipline" | "api" | "none";
  replayBytes: number;              // server-side ring size (0 = none)
  cwdReporting: "osc7" | "poll" | "none";
};

/** WS close codes — the failure taxonomy the frontend renders verbatim. */
export const PTY_CLOSE = {
  AUTH_FAILED: 4001,
  GATE_OFF: 4003,
  NO_SANDBOX: 4004,
  UNSUPPORTED_LANG: 4008,
  PAYLOAD_OVERFLOW: 4013,
  THROTTLED: 4029,
} as const;

export type PtySessionId = string; // server-derived: (user, workspace, termN)

export interface PtySession {
  readonly id: PtySessionId;
  /** Attach a client: receives the replay ring, then live bytes. Detach leaves the shell running. */
  attach(sink: (chunk: Uint8Array) => void, signal: AbortSignal): void;
  writeStdin(chunk: Uint8Array): void;  // bounded queue; overflow → close(PAYLOAD_OVERFLOW)
  resize(cols: number, rows: number): void;
  dispose(): Promise<void>;
  readonly lastActivityMs: number;
  readonly clientCount: number;
}

export interface PtyProvider {
  capabilities(): PtyCapabilities;
  /** Ensure backing sandbox exists (ADR-002 §3), then spawn or return the live session. */
  ensure(user: string, workspace: string, term: number): Promise<PtySession>;
  sessions(user: string, workspace: string): Promise<PtySessionId[]>;
}

/* ─────────────────────── ADR-003 · Language manifest ─────────────────────── */

export type LanguageTier = 1 | 2 | 3;

export type LanguageManifest = {
  id: string;                        // "python"
  name: string;                      // "Python"
  detect: {
    extensions: readonly string[];   // ["py"]
    filenames?: readonly string[];   // ["Dockerfile"]
    shebangs?: readonly string[];    // ["python3", "python"]
  };
  editor?: {
    cm: string;                      // CodeMirror loader key (Lezer host; ADR-003 §6)
    accent: string;                  // "#3572A5"
  };
  lsp?: { server: string; docLanguageId: string };   // server key resolved by the bridge
  runner?: { file: string; cmd: string };            // Plane A: {file} template, one-shot
  pty?: { runCmd: string };                          // Plane B: {file} template, interactive
  fmt?: {
    browser?: { parser: string; plugins: readonly string[] }; // prettier-in-browser
    sandbox?: { argv: readonly string[] };                    // e.g. ["clang-format", …]
  };
  /** Reserved (schema only this engagement — stated in ADR-003 §2). */
  dap?: { adapter: string; argv: readonly string[] };
  /** Multi-step projects (compile → link → run), consumed from Phase 4. */
  project?: {
    detect: readonly string[];       // globs: ["Cargo.toml"]
    steps?: readonly { id: string; cmd: string; needs?: readonly string[] }[];
  };
  /** Toolchain binaries the doctor probes; absence degrades the computed tier honestly. */
  requires?: readonly string[];
};

/** Tier is COMPUTED (ADR-003 §3) — never declared in the manifest. */
export function tierOf(m: LanguageManifest, toolchainOk: boolean): LanguageTier {
  const t1 = Boolean((m.lsp || m.runner || m.pty || m.fmt) && toolchainOk);
  if (t1) return 1;
  return m.editor ? 2 : 3;
}
