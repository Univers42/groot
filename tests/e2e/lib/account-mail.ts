import { createHmac } from "node:crypto";
import { expect, request } from "@playwright/test";
import { GATEWAY_URL, KONG_ANON_KEY, KONG_URL, MAILPIT_URL, PRISMATICA_URL } from "./env";

// The account-mail specs (pr1-pr4) drive the gateway's HTTP contract, the one the site's
// /auth/confirm and /auth/reset-password pages call, and read the links out of Mailpit.
// tests/e2e/run.sh lets them run only on a local backend whose gateway and GoTrue both mail
// Mailpit (scripts/lib/e2e-mail-guard.sh, verdict B C11 C12).

// The local gateway accepts this placeholder only when TURNSTILE_BYPASS_LOCAL=true.
export const TURNSTILE = "localhost-turnstile-token";
export const SPEC_PASSWORD = "Pr-Spec-Pass-2026!";
export const NEW_PASSWORD = "Pr-Spec-Changed-2026!";
// apps/opposite-osiris/scripts/auth/account-mail.mjs ACCOUNT_MAIL_ACCEPTED / REGISTER_ACCEPTED.
export const ACCOUNT_MAIL_ACCEPTED = "If an account can receive mail at that address, a message is on its way. Check your inbox.";
export const REGISTER_ACCEPTED = "Check your inbox to finish creating your account.";
export const SUBJECTS = {
  confirm: "Confirm your email",
  reset: "Reset your password",
  changed: "Your password was changed",
  exists: "You already have an account",
} as const;

let serial = 0;
/** A per-run address: example.test is on the gateway's local-SMTP allowlist; e2e-pr* names the spec's leftovers. */
export function reservedAddress(spec: string): string {
  serial += 1;
  return `e2e-${spec}-${Date.now()}-${serial}@example.test`;
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
  /** The refresh cookie the answer set, as a `name=value` Cookie header ("" if none). */
  cookie: string;
  ms: number;
}

/**
 * One POST to the gateway. A 429 waits out its Retry-After and is sent again, so a per-IP
 * rate limit never reads as the answer under test; `ms` is the answered attempt's time.
 */
export async function gateway(path: string, body: unknown, headers: Record<string, string> = {}): Promise<Answer> {
  const api = await request.newContext();
  try {
    for (let attempt = 0; attempt < 12; attempt += 1) {
      const started = performance.now();
      const res = await api.post(`${GATEWAY_URL}${path}`, { data: body, headers });
      const ms = performance.now() - started;
      if (res.status() === 429) {
        await new Promise((done) => setTimeout(done, (Number(res.headers()["retry-after"] ?? 5) + 1) * 1000));
        continue;
      }
      const setCookie = res.headersArray().find((h) => h.name.toLowerCase() === "set-cookie")?.value ?? "";
      return { status: res.status(), body: (await res.json().catch(() => ({}))) as Record<string, unknown>, cookie: setCookie.split(";")[0] ?? "", ms };
    }
    throw new Error(`${path}: still rate-limited after 12 waits`);
  } finally {
    await api.dispose();
  }
}

export const register = (email: string, password = SPEC_PASSWORD, username = `pr_${Date.now()}_${serial}`) =>
  gateway("/api/auth/register", { email, password, turnstileToken: TURNSTILE, profile: { username, confirmPassword: password } });
export const login = (email: string, password: string) => gateway("/api/auth/login", { email, password, turnstileToken: TURNSTILE });
export const recover = (email: string) => gateway("/api/auth/recover", { email, turnstileToken: TURNSTILE });
export const resend = (email: string) => gateway("/api/auth/resend-verification", { email, turnstileToken: TURNSTILE });

interface MailSummary {
  ID: string;
  Subject: string;
}

/** Every message Mailpit holds for `address` with `subject`, newest first. */
export async function mailsTo(address: string, subject: string): Promise<MailSummary[]> {
  const api = await request.newContext();
  try {
    const res = await api.get(`${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:"${address}"`)}`);
    expect(res.status(), `Mailpit search at ${MAILPIT_URL}`).toBe(200);
    const found = ((await res.json()) as { messages?: MailSummary[] }).messages ?? [];
    return found.filter((m) => m.Subject === subject);
  } finally {
    await api.dispose();
  }
}

/** Waits until Mailpit holds at least `count` such messages; returns them, newest first. */
export async function waitForMails(address: string, subject: string, count = 1, timeout = 30_000): Promise<MailSummary[]> {
  await expect
    .poll(async () => (await mailsTo(address, subject)).length, { message: `${count} "${subject}" mail(s) to ${address}`, timeout })
    .toBeGreaterThanOrEqual(count);
  return mailsTo(address, subject);
}

/** The text part of one message. */
export async function mailText(id: string): Promise<string> {
  const api = await request.newContext();
  try {
    const res = await api.get(`${MAILPIT_URL}/api/v1/message/${encodeURIComponent(id)}`);
    expect(res.status()).toBe(200);
    return String(((await res.json()) as { Text?: string }).Text ?? "");
  } finally {
    await api.dispose();
  }
}

export interface LinkFields {
  token_hash: string;
  type: string;
  exp: string;
  sig: string;
}

/** The signed link a message carries to `${PRISMATICA_URL}/auth/<page>`, as its fragment fields. */
export async function linkIn(id: string, page: "confirm" | "reset-password"): Promise<LinkFields> {
  const text = await mailText(id);
  const prefix = `${PRISMATICA_URL}/auth/${page}#`;
  const url = text.split(/\s+/).find((word) => word.startsWith(prefix));
  if (!url) throw new Error(`no ${prefix} link in message ${id}`);
  const fields = new URLSearchParams(url.slice(prefix.length));
  const pick = (key: string) => fields.get(key) ?? "";
  return { token_hash: pick("token_hash"), type: pick("type"), exp: pick("exp"), sig: pick("sig") };
}

/** A signed-in account: registered, and confirmed through its mail when the stack verifies email. */
export async function confirmedAccount(spec: string, password = SPEC_PASSWORD): Promise<string> {
  const email = reservedAddress(spec);
  const reg = await register(email, password);
  if (reg.status === 202) {
    const [mail] = await waitForMails(email, SUBJECTS.confirm);
    const verified = await gateway("/api/auth/verify", await linkIn(mail!.ID, "confirm"));
    expect(verified.status, `confirming ${email}`).toBe(200);
  } else {
    expect(reg.status, `registering ${email}: ${String(reg.body.message)}`).toBe(200);
  }
  return email;
}

/** A GoTrue call through Kong with the public anon key, for what the gateway does not proxy. */
export async function kong(method: "GET" | "POST", path: string, bearer: string, body?: unknown): Promise<Record<string, unknown>> {
  const api = await request.newContext();
  try {
    const res = await api.fetch(`${KONG_URL}${path}`, { method, data: body, headers: { apikey: KONG_ANON_KEY, authorization: `Bearer ${bearer}` } });
    const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    expect(res.ok(), `${method} ${path}: HTTP ${res.status()} ${JSON.stringify(json).slice(0, 200)}`).toBe(true);
    return json;
  } finally {
    await api.dispose();
  }
}

/** RFC 6238 TOTP (SHA-1, 30 s, 6 digits) from a base32 secret, as an authenticator app computes it. */
export function totp(secret: string, at = Date.now()): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const char of secret.replace(/=+$/, "").toUpperCase()) bits += alphabet.indexOf(char).toString(2).padStart(5, "0");
  const key = Buffer.from((bits.match(/.{8}/g) ?? []).map((byte) => parseInt(byte, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 30_000)));
  const mac = createHmac("sha1", key).update(counter).digest();
  const offset = mac[mac.length - 1]! & 0x0f;
  return String((mac.readUInt32BE(offset) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

export function median(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}
