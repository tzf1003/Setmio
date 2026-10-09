import type { Context, MiddlewareHandler } from "hono";

import { ProxyError } from "./errors.js";
import type { KVStore } from "./store.js";

/** Route names used in rate-limit keys and logs. */
export type RouteName = "devices/register" | "food/recognize" | "food/parse-text" | "coach/chat" | "report/weekly";

export interface Limits {
  /** per IP per hour */
  "devices/register": number;
  /** the rest are per device per UTC day */
  "food/recognize": number;
  "food/parse-text": number;
  "coach/chat": number;
  "report/weekly": number;
}

export const DEFAULT_LIMITS: Limits = {
  "devices/register": 5,
  "food/recognize": 60,
  "food/parse-text": 100,
  "coach/chat": 200,
  "report/weekly": 7,
};

export function utcDayKey(now: Date): string {
  return now.toISOString().slice(0, 10); // yyyy-mm-dd
}

export function utcHourKey(now: Date): string {
  return now.toISOString().slice(0, 13); // yyyy-mm-ddThh
}

export function secondsUntilNextUtcDay(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

export function secondsUntilNextUtcHour(now: Date): number {
  const next = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), now.getUTCHours() + 1);
  return Math.max(1, Math.ceil((next - now.getTime()) / 1000));
}

export function clientIp(c: Context): string {
  return (
    c.req.header("cf-connecting-ip") ??
    c.req.header("x-forwarded-for")?.split(",")[0]?.trim() ??
    c.req.header("x-real-ip") ??
    "unknown"
  );
}

interface RateLimitOptions {
  store: KVStore;
  limits: Limits;
  now: () => Date;
}

/** Per-device daily quota: key `rl:<deviceId>:<route>:<yyyy-mm-dd>`. Requires `bearerAuth` before it. */
export function deviceRateLimit(
  route: Exclude<RouteName, "devices/register">,
  options: RateLimitOptions,
): MiddlewareHandler<{ Variables: { device: { deviceId: string } } }> {
  return async (c, next) => {
    const now = options.now();
    const device = c.get("device");
    const key = `rl:${device.deviceId}:${route}:${utcDayKey(now)}`;
    const ttl = secondsUntilNextUtcDay(now);
    const count = await options.store.increment(key, ttl);
    const limit = options.limits[route];
    c.header("X-RateLimit-Limit", String(limit));
    c.header("X-RateLimit-Remaining", String(Math.max(0, limit - count)));
    if (count > limit) {
      throw new ProxyError("rate_limited", `今日 ${route} 额度已用完（${limit}/天）`, {
        retryable: true,
        retryAfterSeconds: ttl,
      });
    }
    await next();
  };
}

/** Registration: key `rl:ip:<ip>:devices/register:<yyyy-mm-ddThh>`, 5 per hour by default. */
export function registerRateLimit(options: RateLimitOptions): MiddlewareHandler {
  return async (c, next) => {
    const now = options.now();
    const ip = clientIp(c);
    const key = `rl:ip:${ip}:devices/register:${utcHourKey(now)}`;
    const ttl = secondsUntilNextUtcHour(now);
    const count = await options.store.increment(key, ttl);
    const limit = options.limits["devices/register"];
    if (count > limit) {
      throw new ProxyError("rate_limited", `注册过于频繁（${limit}/小时）`, {
        retryable: true,
        retryAfterSeconds: ttl,
      });
    }
    await next();
  };
}
