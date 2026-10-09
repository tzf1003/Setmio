import { Hono } from "hono";

import { createClaudeBackend } from "./backends/claude.js";
import { DomesticBackend } from "./backends/domestic.js";
import type { AppEnv, Deps } from "./deps.js";
import { configFromEnv, type EnvBindings } from "./env.js";
import { isProxyError, ProxyError } from "./errors.js";
import { consoleLogger, type LogEntry } from "./logging.js";
import { DEFAULT_LIMITS } from "./ratelimit.js";
import { coachRoutes } from "./routes/coach.js";
import { deviceRoutes } from "./routes/devices.js";
import { foodRoutes } from "./routes/food.js";
import { reportRoutes } from "./routes/report.js";
import { MemoryStore, WorkersKVStore, type WorkersKVNamespace } from "./store.js";

export type { Deps } from "./deps.js";

/** Builds the Hono app from explicit dependencies (tests pass fakes). */
export function createApp(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // Request log: route, device hash, latency, status, backend, token usage. Never bodies.
  app.use("*", async (c, next) => {
    const started = Date.now();
    await next();
    const entry: LogEntry = {
      route: c.get("route") ?? c.req.path,
      status: c.res.status,
      latencyMs: Date.now() - started,
    };
    const deviceHash = c.get("deviceHash");
    if (deviceHash) entry.deviceHash = deviceHash;
    const backend = c.get("backend");
    if (backend) entry.backend = backend;
    const model = c.get("model");
    if (model) entry.model = model;
    const usage = c.get("usage");
    if (usage) entry.usage = usage;
    const errorCode = c.res.headers.get("x-setmio-error");
    if (errorCode) entry.errorCode = errorCode;
    deps.log(entry);
  });

  app.get("/healthz", (c) => c.json({ ok: true, backends: Object.keys(deps.backends) }));

  app.route("/v1/devices", deviceRoutes(deps));
  app.route("/v1/food", foodRoutes(deps));
  app.route("/v1/coach", coachRoutes(deps));
  app.route("/v1/report", reportRoutes(deps));

  app.notFound((c) => {
    const error = new ProxyError("invalid_request", `未知路由 ${c.req.method} ${c.req.path}`, { status: 404 });
    c.header("x-setmio-error", error.code);
    return c.json(error.toEnvelope(), 404);
  });

  app.onError((err, c) => {
    const error = isProxyError(err)
      ? err
      : new ProxyError("upstream_error", "代理内部错误", { retryable: true, status: 500, cause: err });
    if (!isProxyError(err)) {
      console.error(JSON.stringify({ level: "error", route: c.req.path, message: err.message }));
    }
    c.header("x-setmio-error", error.code);
    if (error.retryAfterSeconds !== undefined) c.header("Retry-After", String(error.retryAfterSeconds));
    return c.json(error.toEnvelope(), error.status as 400);
  });

  return app;
}

/** Builds production dependencies from environment bindings (Workers `env` or `process.env`). */
export function depsFromEnv(env: EnvBindings | Record<string, unknown>, overrides: Partial<Deps> = {}): Deps {
  const config = configFromEnv(env);
  const kv = (env as EnvBindings).SETMIO_KV as WorkersKVNamespace | undefined;
  const backends: Deps["backends"] = { domestic: new DomesticBackend() };
  if (config.anthropicApiKey) {
    backends.claude = createClaudeBackend(config.anthropicApiKey, config.claudeModel);
  }
  return {
    store: kv && typeof kv.get === "function" ? new WorkersKVStore(kv) : new MemoryStore(),
    config,
    backends,
    limits: DEFAULT_LIMITS,
    now: () => new Date(),
    log: consoleLogger,
    ...overrides,
  };
}

// Cloudflare Workers entry: bindings arrive per request, so the app is built lazily once per isolate.
let workerApp: Hono<AppEnv> | undefined;

export default {
  fetch(request: Request, env: EnvBindings, ctx: unknown): Response | Promise<Response> {
    workerApp ??= createApp(depsFromEnv(env));
    return workerApp.fetch(request, env, ctx as never);
  },
};
