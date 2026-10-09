import type { Context, MiddlewareHandler } from "hono";

import { ProxyError } from "./errors.js";
import type { KVStore } from "./store.js";

export interface DeviceRecord {
  deviceId: string;
  deviceName: string;
  platform: string;
  createdAt: string;
}

export interface AuthVariables {
  device: DeviceRecord;
  /** First 12 hex chars of the token hash, for logs only. */
  deviceHash: string;
}

const encoder = new TextEncoder();

function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/** SHA-256 via Web Crypto (available on Workers and Node ≥ 20). */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return toHex(new Uint8Array(digest));
}

/** 32 random bytes as base64url; shown to the device once, only its hash is stored. */
export function generateDeviceToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function generateDeviceId(): string {
  return `dev_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`;
}

export function deviceKey(tokenHash: string): string {
  return `devices:${tokenHash}`;
}

export async function registerDevice(
  store: KVStore,
  input: { deviceName: string; platform: string; now: Date },
): Promise<{ deviceToken: string; deviceId: string }> {
  const deviceToken = generateDeviceToken();
  const deviceId = generateDeviceId();
  const record: DeviceRecord = {
    deviceId,
    deviceName: input.deviceName.slice(0, 80),
    platform: input.platform,
    createdAt: input.now.toISOString(),
  };
  await store.put(deviceKey(await sha256Hex(deviceToken)), JSON.stringify(record));
  return { deviceToken, deviceId };
}

function bearerFrom(c: Context): string | undefined {
  const header = c.req.header("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match?.[1];
}

/** Resolves the bearer token to a device record or throws `unauthorized`. */
export function bearerAuth(store: KVStore): MiddlewareHandler<{ Variables: AuthVariables }> {
  return async (c, next) => {
    const token = bearerFrom(c);
    if (!token || token.length < 16) {
      throw new ProxyError("unauthorized", "缺少或无效的设备令牌");
    }
    const hash = await sha256Hex(token);
    const raw = await store.get(deviceKey(hash));
    if (!raw) {
      throw new ProxyError("unauthorized", "设备未注册，请用邀请码重新注册");
    }
    let record: DeviceRecord;
    try {
      record = JSON.parse(raw) as DeviceRecord;
    } catch {
      throw new ProxyError("unauthorized", "设备记录损坏，请重新注册");
    }
    c.set("device", record);
    c.set("deviceHash", hash.slice(0, 12));
    await next();
  };
}
