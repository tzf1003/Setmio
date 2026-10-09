import { Hono } from "hono";

import { bearerAuth } from "../auth.js";
import { deviceRateLimit } from "../ratelimit.js";
import type { AppEnv, Deps } from "../deps.js";
import { CoachChatRequestSchema, CoachChatResponseSchema } from "../schemas/coach.js";
import { parseBody, recordUsage, selectBackend } from "./shared.js";

export function coachRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const limits = { store: deps.store, limits: deps.limits, now: deps.now };

  app.post("/chat", bearerAuth(deps.store), deviceRateLimit("coach/chat", limits), async (c) => {
    c.set("route", "coach/chat");
    const body = await parseBody(c, CoachChatRequestSchema);
    const backend = selectBackend(c, deps);
    const result = await backend.chat(body);
    recordUsage(c, result);
    return c.json(CoachChatResponseSchema.parse(result.result), 200);
  });

  return app;
}
