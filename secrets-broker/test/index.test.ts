import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import worker from "../src/index";

// Canonical round-trip pair: OTP -> openssl sha256_hex(OTP). Proves the worker's
// Web Crypto hashing matches `openssl dgst -sha256 -hex` byte-for-byte.
const OTP = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const HASH = "a8ae6e6ee929abea3afcfc5258c8ccd6f85273e0d4626d26c7279f3250f77c8e";

const access = { "Cf-Access-Jwt-Assertion": "valid" };

async function call(path: string, headers?: Record<string, string>, envOverride?: unknown) {
  const req = new Request(`https://secrets.tjw.dev${path}`, headers ? { headers } : undefined);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, (envOverride ?? env) as never, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

const kv = () =>
  (env as unknown as {
    OTP_KV: { put(k: string, v: string): Promise<void>; get(k: string): Promise<string | null>; delete(k: string): Promise<void> };
  }).OTP_KV;

beforeEach(async () => {
  await kv().delete(HASH);
});

describe("secrets broker (path-scoped + OTP)", () => {
  it("returns the pr-agent bundle for a valid unused OTP, then burns it", async () => {
    await kv().put(HASH, "pr-agent");
    const res = await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP });
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(Object.keys(body).sort()).toEqual([
      "DEEPSEEK_API_KEY",
      "GITHUB_APP_ID",
      "GITHUB_APP_PRIVATE_KEY",
      "GITHUB_WEBHOOK_SECRET",
      "TUNNEL_CRED",
    ]);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await kv().get(HASH)).toBeNull(); // burned
  });

  it("rejects a replay of a consumed OTP with 410", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(200);
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(410);
  });

  it("410 when the OTP header is missing", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", access)).status).toBe(410);
  });

  it("410 for a malformed OTP (uppercase or wrong length)", async () => {
    await kv().put(HASH, "pr-agent");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP.toUpperCase() })).status).toBe(410);
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": "abc" })).status).toBe(410);
  });

  it("410 when the OTP is scoped to a different namespace", async () => {
    await kv().put(HASH, "other-project");
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP })).status).toBe(410);
  });

  it("401 when the Access assertion is missing (before OTP)", async () => {
    expect((await call("/secrets/pr-agent", { "X-Secrets-OTP": OTP })).status).toBe(401);
  });

  it("404 on unknown namespace / bare /secrets / other paths", async () => {
    expect((await call("/secrets/codevibes", { ...access, "X-Secrets-OTP": OTP })).status).toBe(404);
    expect((await call("/secrets", access)).status).toBe(404);
    expect((await call("/", access)).status).toBe(404);
  });

  it("500 (fail closed) when the OTP_KV binding is missing", async () => {
    const broken = { ...(env as object), OTP_KV: undefined };
    expect((await call("/secrets/pr-agent", { ...access, "X-Secrets-OTP": OTP }, broken)).status).toBe(500);
  });
});
