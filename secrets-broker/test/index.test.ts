import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

const goodHeaders = { "Cf-Access-Jwt-Assertion": "valid" };

describe("pr-agent secrets broker", () => {
  it("returns all five secrets to an Access-authenticated request", async () => {
    const req = new Request("https://pr-agent-secrets.tjw.dev/secrets", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(200);
    const body = await res.json<Record<string, string>>();
    expect(body.DEEPSEEK_API_KEY).toBeTruthy();
    expect(body.GITHUB_APP_PRIVATE_KEY).toBeTruthy();
    expect(body.GITHUB_APP_ID).toBeTruthy();
    expect(body.GITHUB_WEBHOOK_SECRET).toBeTruthy();
    expect(body.TUNNEL_CRED).toBeTruthy();
  });

  it("rejects a request with no Access assertion (401)", async () => {
    const req = new Request("https://pr-agent-secrets.tjw.dev/secrets");
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(401);
  });

  it("404s on any path other than /secrets", async () => {
    const req = new Request("https://pr-agent-secrets.tjw.dev/", { headers: goodHeaders });
    const ctx = createExecutionContext();
    const res = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(404);
  });
});
