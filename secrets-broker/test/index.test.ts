import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const goodHeaders = { "Cf-Access-Jwt-Assertion": "valid" };

// Shared secrets broker (secrets.tjw.dev). Path-scoped per namespace:
//   GET /secrets/<project> -> that project's bundle. Today only `pr-agent`.
async function call(path: string, headers?: HeadersInit) {
  const req = new Request(`https://secrets.tjw.dev${path}`, headers ? { headers } : undefined);
  const ctx = createExecutionContext();
  const res = await worker.fetch(req, env, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

describe("secrets broker (path-scoped)", () => {
  it("returns the pr-agent bundle to an Access-authenticated request", async () => {
    const res = await call("/secrets/pr-agent", goodHeaders);
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(body.DEEPSEEK_API_KEY).toBeTruthy();
    expect(body.GITHUB_APP_PRIVATE_KEY).toBeTruthy();
    expect(body.GITHUB_APP_ID).toBeTruthy();
    expect(body.GITHUB_WEBHOOK_SECRET).toBeTruthy();
    expect(body.TUNNEL_CRED).toBeTruthy();
  });

  it("scopes the bundle to exactly the pr-agent keys (no cross-namespace leak)", async () => {
    const res = await call("/secrets/pr-agent", goodHeaders);
    const body = await res.json<Record<string, string>>();
    expect(Object.keys(body).sort()).toEqual([
      "DEEPSEEK_API_KEY",
      "GITHUB_APP_ID",
      "GITHUB_APP_PRIVATE_KEY",
      "GITHUB_WEBHOOK_SECRET",
      "TUNNEL_CRED",
    ]);
  });

  it("rejects a request with no Access assertion (401)", async () => {
    const res = await call("/secrets/pr-agent");
    expect(res.status).toBe(401);
  });

  it("404s on an unknown namespace", async () => {
    const res = await call("/secrets/codevibes", goodHeaders);
    expect(res.status).toBe(404);
  });

  it("404s on the bare /secrets path (a namespace is required)", async () => {
    const res = await call("/secrets", goodHeaders);
    expect(res.status).toBe(404);
  });

  it("404s on any other path", async () => {
    const res = await call("/", goodHeaders);
    expect(res.status).toBe(404);
  });
});
