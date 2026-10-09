import { ProxyError } from "../errors.js";
import type { BackendResult, ModelBackend } from "./types.js";
import type { CoachChatRequest, CoachChatResponse } from "../schemas/coach.js";
import type { FoodParseTextRequest, FoodRecognitionResult, FoodRecognizeRequest } from "../schemas/food.js";
import type { WeeklyReportRequest, WeeklyReportResponse } from "../schemas/report.js";

/**
 * Placeholder for a PRC-registered model (V3). Same prompts and schemas; only the transport differs.
 * Until configured every call reports `backend_unavailable` so the app can fall back or show a hint.
 */
export class DomesticBackend implements ModelBackend {
  readonly provider = "domestic";

  private unavailable(): never {
    throw new ProxyError("backend_unavailable", "国产模型后端尚未配置", { retryable: false });
  }

  async recognizeFood(_req: FoodRecognizeRequest): Promise<BackendResult<FoodRecognitionResult>> {
    this.unavailable();
  }

  async parseFoodText(_req: FoodParseTextRequest): Promise<BackendResult<FoodRecognitionResult>> {
    this.unavailable();
  }

  async chat(_req: CoachChatRequest): Promise<BackendResult<CoachChatResponse>> {
    this.unavailable();
  }

  async weeklyReport(_req: WeeklyReportRequest): Promise<BackendResult<WeeklyReportResponse>> {
    this.unavailable();
  }
}
