// Shared secrets broker for secrets.tjw.dev. Sits behind Cloudflare Access
// (service-token policy). Defense in depth: require the Access assertion header.
//
// Path-scoped per namespace: GET /secrets/<project> returns only that project's
// bundle. Today the only namespace is `pr-agent`; adding another project is a
// single entry in BUNDLES below plus its Secrets Store bindings in wrangler.toml.
// A bundle never sees another namespace's keys, so one broker can serve many
// projects without cross-leaking secrets.

// Production bindings are Secrets Store objects ({ get(): Promise<string> }).
// Test bindings (vitest.config.ts miniflare.bindings) are plain strings.
// SecretsBinding covers both so the Worker runs hermetically in vitest.
type SecretsBinding = string | { get(): Promise<string> };

export interface Env {
  // pr-agent namespace.
  DEEPSEEK_API_KEY: SecretsBinding;
  GITHUB_APP_PRIVATE_KEY: SecretsBinding;
  GITHUB_APP_ID: SecretsBinding;
  GITHUB_WEBHOOK_SECRET: SecretsBinding;
  TUNNEL_CRED: SecretsBinding;
}

// Each namespace maps to the bindings it exposes. The response keys are the map
// keys; the values are the bindings to resolve. Add future projects here.
const BUNDLES: Record<string, (env: Env) => Record<string, SecretsBinding>> = {
  "pr-agent": (env) => ({
    DEEPSEEK_API_KEY: env.DEEPSEEK_API_KEY,
    GITHUB_APP_PRIVATE_KEY: env.GITHUB_APP_PRIVATE_KEY,
    GITHUB_APP_ID: env.GITHUB_APP_ID,
    GITHUB_WEBHOOK_SECRET: env.GITHUB_WEBHOOK_SECRET,
    TUNNEL_CRED: env.TUNNEL_CRED,
  }),
};

// Resolve a binding to its string value — handles both Secrets Store and plain-var forms.
async function resolve(b: SecretsBinding): Promise<string> {
  return typeof b === "string" ? b : b.get();
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    // Only /secrets/<namespace> is routable. Anything else (including bare
    // /secrets) is 404 — a namespace is required.
    const m = url.pathname.match(/^\/secrets\/([a-z0-9-]+)$/);
    const bundle = m ? BUNDLES[m[1]] : undefined;
    if (!bundle) return new Response("not found", { status: 404 });
    // Access injects this header once its policy passes. Absent => not via Access.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }
    const spec = bundle(env);
    const entries = await Promise.all(
      Object.entries(spec).map(async ([k, b]) => [k, await resolve(b)] as const),
    );
    return Response.json(Object.fromEntries(entries), {
      headers: { "cache-control": "no-store" },
    });
  },
};
