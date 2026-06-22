import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersConfig({
  css: { postcss: { plugins: [] } },
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        // Test-only stub bindings live HERE, not in wrangler.toml, so the deploy
        // config never carries secret-shaped fields (no leak surface, no prod
        // collision with the Secrets Store bindings).
        miniflare: {
          bindings: {
            DEEPSEEK_API_KEY: "test-deepseek-key",
            GITHUB_APP_PRIVATE_KEY: "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----\n",
            GITHUB_APP_ID: "123456",
            GITHUB_WEBHOOK_SECRET: "test-webhook-secret",
            TUNNEL_CRED: '{"TunnelID":"test-tunnel"}',
          },
        },
      },
    },
  },
});
