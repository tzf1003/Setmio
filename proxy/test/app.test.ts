import { beforeEach, describe, expect, it } from "vitest";

import { createApp, type Deps } from "../src/index.js";
import type { LogEntry } from "../src/logging.js";
import { DEFAULT_LIMITS } from "../src/ratelimit.js";
import { FoodRecognitionResultSchema } from "../src/schemas/food.js";
import { MemoryStore } from "../src/store.js";
import { FakeBackend, refusal } from "./fake-backend.js";

const INVITE = "test-invite-code";

interface Harness {
  app: ReturnType<typeof createApp>;
  backend: FakeBackend;
  store: MemoryStore;
  logs: LogEntry[];
  deps: Deps;
  clock: { now: Date };
}

function harness(overrides: Partial<Deps> = {}): Harness {
  const backend = new FakeBackend();
  const clock = { now: new Date("2026-10-09T08:00:00Z") };
  const store = new MemoryStore(() => clock.now.getTime());
  const logs: LogEntry[] = [];
  const deps: Deps = {
    store,
    config: { inviteCode: INVITE, allowBackendOverride: false, defaultBackend: "claude", claudeModel: "claude-opus-5-5" },
    backends: { claude: backend },
    limits: DEFAULT_LIMITS,
    now: () => clock.now,
    log: (entry) => logs.push(entry),
    ...overrides,
  };
  return { app: createApp(deps), backend, store, logs, deps, clock };
}

function post(app: Harness["app"], path: string, body: unknown, headers: Record<string, string> = {}) {
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function register(h: Harness, ip = "203.0.113.1"): Promise<{ deviceToken: string; deviceId: string }> {
  const res = await post(
    h.app,
    "/v1/devices/register",
    { inviteCode: INVITE, deviceName: "iPhone 17", platform: "ios" },
    { "cf-connecting-ip": ip },
  );
  expect(res.status).toBe(200);
  return (await res.json()) as { deviceToken: string; deviceId: string };
}

const recognizeBody = {
  imageJpegBase64: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBD".repeat(2),
  imageWidth: 1536,
  imageHeight: 1152,
  hints: { mealType: "lunch", locale: "zh-CN", userNote: "外卖" },
};

describe("proxy app", () => {
  let h: Harness;

  beforeEach(() => {
    h = harness();
  });

  it("returns 401 without a token", async () => {
    const res = await post(h.app, "/v1/food/recognize", recognizeBody);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string; retryable: boolean } };
    expect(body.error.code).toBe("unauthorized");
    expect(body.error.retryable).toBe(false);
    expect(h.backend.calls).toHaveLength(0);
  });

  it("returns 401 for an unknown token and a wrong invite code", async () => {
    const res = await post(h.app, "/v1/coach/chat", { messages: [{ role: "user", content: "hi" }] }, {
      authorization: "Bearer not-a-registered-token-at-all",
    });
    expect(res.status).toBe(401);

    const bad = await post(h.app, "/v1/devices/register", { inviteCode: "nope", deviceName: "x" });
    expect(bad.status).toBe(401);
    expect(((await bad.json()) as { error: { code: string } }).error.code).toBe("unauthorized");
  });

  it("register + authenticated food/recognize returns a valid FoodRecognitionResult", async () => {
    const { deviceToken, deviceId } = await register(h);
    expect(deviceToken.length).toBeGreaterThanOrEqual(40);
    expect(deviceId.startsWith("dev_")).toBe(true);
    // Only the hash is stored.
    const keys = await Promise.all([h.store.get(`devices:${deviceToken}`)]);
    expect(keys[0]).toBeNull();

    const res = await post(h.app, "/v1/food/recognize", recognizeBody, { authorization: `Bearer ${deviceToken}` });
    expect(res.status).toBe(200);
    const parsed = FoodRecognitionResultSchema.parse(await res.json());
    expect(parsed.items.map((i) => i.nameZH)).toEqual(["番茄炒蛋", "米饭", "紫菜蛋花汤"]);
    expect(res.headers.get("x-ratelimit-remaining")).toBe("59");

    expect(h.backend.calls).toHaveLength(1);
    const call = h.backend.calls[0]!.request as { hints: { mealType: string; locale: string } };
    expect(call.hints).toEqual({ mealType: "lunch", locale: "zh-CN", userNote: "外卖" });

    const log = h.logs.at(-1)!;
    expect(log.route).toBe("food/recognize");
    expect(log.status).toBe(200);
    expect(log.deviceHash).toHaveLength(12);
    expect(log.usage).toEqual({ inputTokens: 10, outputTokens: 5 });
    expect(JSON.stringify(log)).not.toContain(recognizeBody.imageJpegBase64);
    expect(JSON.stringify(log)).not.toContain(deviceToken);
  });

  it("parse-text, chat and weekly report round-trip through their schemas", async () => {
    const { deviceToken } = await register(h);
    const auth = { authorization: `Bearer ${deviceToken}` };

    const text = await post(h.app, "/v1/food/parse-text", { text: "一碗米饭 番茄炒蛋", locale: "zh-CN" }, auth);
    expect(text.status).toBe(200);

    const chat = await post(
      h.app,
      "/v1/coach/chat",
      { messages: [{ role: "user", content: "今天能练腿吗" }], context: { readinessScore: 70 }, locale: "zh-CN" },
      auth,
    );
    expect(chat.status).toBe(200);
    expect(await chat.json()).toEqual({ replyZH: "可以练，按计划走。", suggestions: ["热身 10 分钟"], safetyFlags: [] });

    const report = await post(
      h.app,
      "/v1/report/weekly",
      {
        weekStart: "2026-10-05",
        metrics: { avgReadiness: 68 },
        training: { sessions: 3 },
        nutrition: { avgProteinG: 130 },
        medication: { adherencePct: 100, sideEffectSummary: "轻度恶心 2 天" },
      },
      auth,
    );
    expect(report.status).toBe(200);
    expect(((await report.json()) as { titleZH: string }).titleZH).toBe("稳步前进的一周");

    const invalid = await post(h.app, "/v1/coach/chat", { messages: [] }, auth);
    expect(invalid.status).toBe(400);
    expect(((await invalid.json()) as { error: { code: string } }).error.code).toBe("invalid_request");
  });

  it("rate limits food/recognize after the daily limit with a 429 envelope", async () => {
    h = harness({ limits: { ...DEFAULT_LIMITS, "food/recognize": 3 } });
    const { deviceToken } = await register(h);
    const auth = { authorization: `Bearer ${deviceToken}` };

    for (let i = 0; i < 3; i++) {
      const ok = await post(h.app, "/v1/food/recognize", recognizeBody, auth);
      expect(ok.status).toBe(200);
    }
    const limited = await post(h.app, "/v1/food/recognize", recognizeBody, auth);
    expect(limited.status).toBe(429);
    const body = (await limited.json()) as { error: { code: string; retryable: boolean; retryAfterSeconds: number } };
    expect(body.error.code).toBe("rate_limited");
    expect(body.error.retryable).toBe(true);
    // 08:00Z → next UTC day is 16 h away.
    expect(body.error.retryAfterSeconds).toBe(16 * 3600);
    expect(limited.headers.get("retry-after")).toBe(String(16 * 3600));
    expect(h.backend.calls).toHaveLength(3);

    // Counter key shape and reset on the next day.
    expect(await h.store.get(`rl:${(await h.store.get(`rl:x`)) ?? ""}`)).toBeNull();
    h.clock.now = new Date("2026-10-10T00:00:01Z");
    const nextDay = await post(h.app, "/v1/food/recognize", recognizeBody, auth);
    expect(nextDay.status).toBe(200);
  });

  it("rate limits registration per IP per hour (5)", async () => {
    for (let i = 0; i < 5; i++) await register(h, "198.51.100.7");
    const sixth = await post(
      h.app,
      "/v1/devices/register",
      { inviteCode: INVITE, deviceName: "x", platform: "ios" },
      { "cf-connecting-ip": "198.51.100.7" },
    );
    expect(sixth.status).toBe(429);
    const otherIp = await register(h, "198.51.100.8");
    expect(otherIp.deviceId.startsWith("dev_")).toBe(true);
  });

  it("maps a model refusal to upstream_refusal (422, not retryable)", async () => {
    const { deviceToken } = await register(h);
    h.backend.failWith = refusal();
    const res = await post(h.app, "/v1/food/parse-text", { text: "x", locale: "zh-CN" }, { authorization: `Bearer ${deviceToken}` });
    expect(res.status).toBe(422);
    const body = (await res.json()) as { error: { code: string; retryable: boolean } };
    expect(body.error).toMatchObject({ code: "upstream_refusal", retryable: false });
    expect(h.logs.at(-1)?.errorCode).toBe("upstream_refusal");
  });

  it("returns image_too_large for a body over 2 MB", async () => {
    const { deviceToken } = await register(h);
    const huge = { ...recognizeBody, imageJpegBase64: "A".repeat(2 * 1024 * 1024 + 1024) };
    const res = await post(h.app, "/v1/food/recognize", huge, { authorization: `Bearer ${deviceToken}` });
    expect(res.status).toBe(413);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("image_too_large");
    expect(h.backend.calls).toHaveLength(0);
  });

  it("honours X-Setmio-Backend only when overrides are allowed, and reports missing backends", async () => {
    const { deviceToken } = await register(h);
    const auth = { authorization: `Bearer ${deviceToken}` };

    const ignored = await post(h.app, "/v1/coach/chat", { messages: [{ role: "user", content: "hi" }] }, {
      ...auth,
      "x-setmio-backend": "domestic",
    });
    expect(ignored.status).toBe(200);

    const strict = harness({
      store: h.store,
      config: { ...h.deps.config, allowBackendOverride: true },
      backends: { claude: h.backend },
    });
    const missing = await post(strict.app, "/v1/coach/chat", { messages: [{ role: "user", content: "hi" }] }, {
      ...auth,
      "x-setmio-backend": "domestic",
    });
    expect(missing.status).toBe(503);
    expect(((await missing.json()) as { error: { code: string } }).error.code).toBe("backend_unavailable");
  });

  it("unknown routes and unexpected errors use the envelope", async () => {
    const res = await h.app.request("/v1/nope", { method: "POST" });
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("invalid_request");

    const { deviceToken } = await register(h);
    h.backend.failWith = new Error("boom");
    const crash = await post(h.app, "/v1/coach/chat", { messages: [{ role: "user", content: "hi" }] }, {
      authorization: `Bearer ${deviceToken}`,
    });
    expect(crash.status).toBe(500);
    expect(((await crash.json()) as { error: { code: string; retryable: boolean } }).error).toMatchObject({
      code: "upstream_error",
      retryable: true,
    });
  });
});
