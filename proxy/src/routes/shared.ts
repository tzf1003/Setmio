import type { Context } from "hono";
import type { z } from "zod";

import type { ModelBackend } from "../backends/types.js";
import { ProxyError } from "../errors.js";
import type { AppEnv, Deps } from "../deps.js";

/** Parses JSON and validates against a zod schema; any failure is an `invalid_request` envelope. */
export async function parseBody<S extends z.ZodType>(c: Context<AppEnv>, schema: S): Promise<z.infer<S>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw new ProxyError("invalid_request", "请求体不是合法 JSON");
  }
  const parsed = schema.safeParse(raw);
  if (!parsed.success) {
    const first = parsed.error.issues[0];
    const where = first?.path.length ? `${first.path.map(String).join(".")}: ` : "";
    throw new ProxyError("invalid_request", `${where}${first?.message ?? "请求格式错误"}`);
  }
  return parsed.data as z.infer<S>;
}

/**
 * Chooses the backend: the `X-Setmio-Backend` hint is honoured only when `ALLOW_BACKEND_OVERRIDE=true`,
 * otherwise the configured default is used. Missing backends surface as `backend_unavailable`.
 */
export function selectBackend(c: Context<AppEnv>, deps: Deps): ModelBackend {
  const hint = c.req.header("x-setmio-backend")?.toLowerCase();
  let name = deps.config.defaultBackend;
  if (deps.config.allowBackendOverride && (hint === "claude" || hint === "domestic")) {
    name = hint;
  }
  const backend = deps.backends[name];
  if (!backend) {
    throw new ProxyError("backend_unavailable", `后端 ${name} 未配置`, { retryable: false });
  }
  c.set("backend", backend.provider);
  return backend;
}

/** Fills response-log fields from a backend result. */
export function recordUsage(c: Context<AppEnv>, result: { modelId: string; usage?: import("../logging.js").TokenUsage }): void {
  c.set("model", result.modelId);
  if (result.usage) c.set("usage", result.usage);
}
