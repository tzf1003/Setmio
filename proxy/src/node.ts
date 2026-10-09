import { serve } from "@hono/node-server";

import { createApp, depsFromEnv } from "./index.js";

const port = Number.parseInt(process.env["PORT"] ?? "8787", 10);
const deps = depsFromEnv(process.env);
const app = createApp(deps);

if (!deps.config.anthropicApiKey) {
  console.warn("ANTHROPIC_API_KEY 未设置：claude 后端不可用，相关路由会返回 backend_unavailable");
}
if (!deps.config.inviteCode) {
  console.warn("INVITE_CODE 未设置：/v1/devices/register 会返回 backend_unavailable");
}

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`setmio-proxy (Node, in-memory store) listening on http://localhost:${info.port}`);
});
