import { Hono } from "hono";
import { z } from "zod";

import { registerDevice } from "../auth.js";
import { ProxyError } from "../errors.js";
import { registerRateLimit } from "../ratelimit.js";
import type { AppEnv, Deps } from "../deps.js";
import { parseBody } from "./shared.js";

export const DeviceRegisterRequestSchema = z.object({
  inviteCode: z.string().min(1).max(128),
  deviceName: z.string().min(1).max(80),
  platform: z.enum(["ios", "watchos", "macos", "other"]).default("ios"),
});

export const DeviceRegisterResponseSchema = z.object({
  deviceToken: z.string(),
  deviceId: z.string(),
});

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i]! ^ y[i]!;
  return diff === 0;
}

export function deviceRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const limiter = registerRateLimit({ store: deps.store, limits: deps.limits, now: deps.now });

  app.post("/register", limiter, async (c) => {
    const body = await parseBody(c, DeviceRegisterRequestSchema);
    const expected = deps.config.inviteCode;
    if (!expected) {
      throw new ProxyError("backend_unavailable", "代理尚未配置邀请码（INVITE_CODE）", { retryable: false });
    }
    if (!constantTimeEqual(body.inviteCode, expected)) {
      throw new ProxyError("unauthorized", "邀请码无效");
    }
    const issued = await registerDevice(deps.store, {
      deviceName: body.deviceName,
      platform: body.platform,
      now: deps.now(),
    });
    return c.json(DeviceRegisterResponseSchema.parse(issued), 200);
  });

  return app;
}
