import type { ModelBackend } from "./backends/types.js";
import type { BackendName, Config } from "./env.js";
import type { Logger, TokenUsage } from "./logging.js";
import type { Limits } from "./ratelimit.js";
import type { KVStore } from "./store.js";
import type { AuthVariables } from "./auth.js";

/** Everything the app needs, injected so tests can swap the store, clock, limits and backends. */
export interface Deps {
  store: KVStore;
  config: Config;
  backends: Partial<Record<BackendName, ModelBackend>>;
  limits: Limits;
  now: () => Date;
  log: Logger;
}

/** Hono context variables set along a request. */
export interface AppVariables extends AuthVariables {
  route: string;
  backend: string;
  model: string;
  usage: TokenUsage;
}

export type AppEnv = { Variables: AppVariables };
