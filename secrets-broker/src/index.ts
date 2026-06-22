// PR-Agent secrets broker. Sits behind Cloudflare Access (service-token policy).
// Defense in depth: require the Access assertion header; only serves /secrets.
//
// This is a SECOND Worker, distinct from the CodeVibes broker. It binds the SAME
// single account Workers Secrets Store, but to its own pr-agent-* secret names —
// see wrangler.toml.

// Production bindings are Secrets Store objects ({ get(): Promise<string> }).
// Test bindings (vitest.config.ts miniflare.bindings) are plain strings.
// SecretsBinding covers both so the Worker runs hermetically in vitest.
type SecretsBinding = string | { get(): Promise<string> };

export interface Env {
  DEEPSEEK_API_KEY: SecretsBinding;
  GITHUB_APP_PRIVATE_KEY: SecretsBinding;
  GITHUB_APP_ID: SecretsBinding;
  GITHUB_WEBHOOK_SECRET: SecretsBinding;
  TUNNEL_CRED: SecretsBinding;
}

// Resolve a binding to its string value — handles both Secrets Store and plain-var forms.
async function resolve(b: SecretsBinding): Promise<string> {
  return typeof b === "string" ? b : b.get();
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/secrets") return new Response("not found", { status: 404 });
    // Access injects this header once its policy passes. Absent => not via Access.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }
    const body = {
      DEEPSEEK_API_KEY: await resolve(env.DEEPSEEK_API_KEY),
      GITHUB_APP_PRIVATE_KEY: await resolve(env.GITHUB_APP_PRIVATE_KEY),
      GITHUB_APP_ID: await resolve(env.GITHUB_APP_ID),
      GITHUB_WEBHOOK_SECRET: await resolve(env.GITHUB_WEBHOOK_SECRET),
      TUNNEL_CRED: await resolve(env.TUNNEL_CRED),
    };
    return Response.json(body, { headers: { "cache-control": "no-store" } });
  },
};
