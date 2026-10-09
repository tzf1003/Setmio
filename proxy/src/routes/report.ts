import { Hono } from "hono";

import { bearerAuth } from "../auth.js";
import { deviceRateLimit } from "../ratelimit.js";
import type { AppEnv, Deps } from "../deps.js";
import { WeeklyReportRequestSchema, WeeklyReportResponseSchema } from "../schemas/report.js";
import { parseBody, recordUsage, selectBackend } from "./shared.js";

export function reportRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const limits = { store: deps.store, limits: deps.limits, now: deps.now };

  app.post("/weekly", bearerAuth(deps.store), deviceRateLimit("report/weekly", limits), async (c) => {
    c.set("route", "report/weekly");
    const body = await parseBody(c, WeeklyReportRequestSchema);
    const backend = selectBackend(c, deps);
    const result = await backend.weeklyReport(body);
    recordUsage(c, result);
    return c.json(WeeklyReportResponseSchema.parse(result.result), 200);
  });

  return app;
}
