import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import type { BackendResult, ModelBackend } from "../src/backends/types.js";
import { ProxyError } from "../src/errors.js";
import type { CoachChatRequest, CoachChatResponse } from "../src/schemas/coach.js";
import {
  FoodRecognitionResultSchema,
  type FoodParseTextRequest,
  type FoodRecognitionResult,
  type FoodRecognizeRequest,
} from "../src/schemas/food.js";
import type { WeeklyReportRequest, WeeklyReportResponse } from "../src/schemas/report.js";

const here = path.dirname(fileURLToPath(import.meta.url));

export function loadFixture<T = unknown>(name: string): T {
  return JSON.parse(readFileSync(path.join(here, "fixtures", name), "utf8")) as T;
}

export const foodFixture = FoodRecognitionResultSchema.parse(loadFixture("food_recognize_response.json"));

/** Scripted backend: returns fixtures, or throws the configured error. Records every call. */
export class FakeBackend implements ModelBackend {
  readonly provider = "fake";
  failWith: ProxyError | Error | undefined;
  calls: Array<{ method: string; request: unknown }> = [];

  private handle<T>(method: string, request: unknown, result: T): BackendResult<T> {
    this.calls.push({ method, request });
    if (this.failWith) throw this.failWith;
    return { result, modelId: "fake-model", usage: { inputTokens: 10, outputTokens: 5 } };
  }

  async recognizeFood(req: FoodRecognizeRequest): Promise<BackendResult<FoodRecognitionResult>> {
    return this.handle("recognizeFood", req, foodFixture);
  }

  async parseFoodText(req: FoodParseTextRequest): Promise<BackendResult<FoodRecognitionResult>> {
    return this.handle("parseFoodText", req, foodFixture);
  }

  async chat(req: CoachChatRequest): Promise<BackendResult<CoachChatResponse>> {
    return this.handle("chat", req, { replyZH: "可以练，按计划走。", suggestions: ["热身 10 分钟"], safetyFlags: [] });
  }

  async weeklyReport(req: WeeklyReportRequest): Promise<BackendResult<WeeklyReportResponse>> {
    return this.handle("weeklyReport", req, {
      titleZH: "稳步前进的一周",
      summaryZH: "训练 3 次，蛋白质达标。",
      highlights: ["3 次力量训练"],
      concerns: [],
      nextWeekFocus: ["保持 3 次训练"],
    });
  }
}

export function refusal(): ProxyError {
  return new ProxyError("upstream_refusal", "模型拒绝处理这个请求", { retryable: false });
}
