/**
 * Environment bindings. On Workers they arrive as the `env` argument of `fetch`;
 * on Node they come from `process.env`. Secrets never appear in wrangler.toml.
 */
export interface EnvBindings {
  ANTHROPIC_API_KEY?: string;
  INVITE_CODE?: string;
  /** "true" lets clients pick a backend with `X-Setmio-Backend`; default off. */
  ALLOW_BACKEND_OVERRIDE?: string;
  /** Default backend when no override: "claude" | "domestic". */
  DEFAULT_BACKEND?: string;
  /** Workers KV binding (absent on Node → in-memory store). */
  SETMIO_KV?: unknown;
}

export type BackendName = "claude" | "domestic";

export interface Config {
  anthropicApiKey?: string;
  inviteCode?: string;
  allowBackendOverride: boolean;
  defaultBackend: BackendName;
  /** Model id for the Claude backend. */
  claudeModel: string;
}

export const CLAUDE_MODEL_ID = "claude-opus-5-5";

function asString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function configFromEnv(env: Record<string, unknown> | EnvBindings): Config {
  const record = env as Record<string, unknown>;
  const backend = asString(record["DEFAULT_BACKEND"]);
  return {
    anthropicApiKey: asString(record["ANTHROPIC_API_KEY"]),
    inviteCode: asString(record["INVITE_CODE"]),
    allowBackendOverride: asString(record["ALLOW_BACKEND_OVERRIDE"])?.toLowerCase() === "true",
    defaultBackend: backend === "domestic" ? "domestic" : "claude",
    claudeModel: asString(record["CLAUDE_MODEL"]) ?? CLAUDE_MODEL_ID,
  };
}
