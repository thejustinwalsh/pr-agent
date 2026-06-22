// Shared secrets broker for secrets.tjw.dev. Sits behind Cloudflare Access
// (service-token policy) and requires a single-use OTP per fetch.
//
// Path-scoped per namespace: GET /secrets/<project> returns only that project's
// bundle. The OTP (X-Secrets-OTP header) is sha256-hashed, looked up in OTP_KV,
// verified against the namespace, and deleted (burned) before the bundle is
// returned. Any OTP failure is a uniform 410; KV errors fail closed (500).
// Adding a project is a single BUNDLES entry plus its Secrets Store bindings in
// wrangler.toml.

// Production bindings are Secrets Store objects ({ get(): Promise<string> }).
// Test bindings (vitest.config.ts miniflare.bindings) are plain strings.
type SecretsBinding = string | { get(): Promise<string> };

// Minimal KV surface the worker uses — only read + delete (never put; minting is CLI-only).
interface OtpKv {
  get(key: string): Promise<string | null>;
  delete(key: string): Promise<void>;
}

export interface Env {
  // pr-agent namespace. All five are Cloudflare Worker secrets (plain strings),
  // set by deploy/set-broker-secrets.sh. resolve() also accepts Secrets Store
  // objects, so a future namespace could mix the two. See wrangler.toml.
  DEEPSEEK_API_KEY: SecretsBinding;
  GITHUB_APP_PRIVATE_KEY: SecretsBinding;
  GITHUB_APP_ID: SecretsBinding;
  GITHUB_WEBHOOK_SECRET: SecretsBinding;
  TUNNEL_CRED: SecretsBinding;
  // Single-use OTP store.
  OTP_KV: OtpKv;
}

// Each namespace maps to the bindings it exposes. Add future projects here.
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

// Lowercase hex SHA-256, matching `openssl dgst -sha256 -hex`.
async function sha256hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const gone = () => new Response("gone", { status: 410 });
const fail = () => new Response("error", { status: 500 });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    // Only /secrets/<namespace> is routable. Anything else (incl. bare /secrets) 404s.
    const m = url.pathname.match(/^\/secrets\/([a-z0-9-]+)$/);
    const namespace = m?.[1];
    const bundle = namespace ? BUNDLES[namespace] : undefined;
    if (!bundle || !namespace) return new Response("not found", { status: 404 });

    // Access injects this header once its service-token policy passes. Absent => not via Access.
    if (!req.headers.get("Cf-Access-Jwt-Assertion")) {
      return new Response("unauthorized", { status: 401 });
    }

    // KV binding must exist — fail closed if misconfigured/undeployed.
    if (env.OTP_KV == null) return fail();

    // Uniform 410 for every OTP failure (no oracle between "missing" and "bad").
    const otp = (req.headers.get("X-Secrets-OTP") ?? "").trim();
    if (!/^[0-9a-f]{64}$/.test(otp)) return gone();

    const hash = await sha256hex(otp);
    let stored: string | null;
    try {
      stored = await env.OTP_KV.get(hash);
    } catch {
      return fail();
    }
    if (stored === null) {
      console.warn(`otp miss for namespace=${namespace}`); // replay/expiry signal
      return gone();
    }
    if (stored !== namespace) return gone();

    // Burn before serving; if the delete fails, do NOT serve secrets with a live OTP.
    try {
      await env.OTP_KV.delete(hash);
    } catch {
      return fail();
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
