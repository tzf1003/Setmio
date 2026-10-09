import type { TokenUsage } from "../logging.js";
import type { CoachChatRequest, CoachChatResponse } from "../schemas/coach.js";
import type { FoodParseTextRequest, FoodRecognitionResult, FoodRecognizeRequest } from "../schemas/food.js";
import type { WeeklyReportRequest, WeeklyReportResponse } from "../schemas/report.js";

export interface BackendResult<T> {
  result: T;
  modelId: string;
  usage?: TokenUsage;
}

/**
 * The only seam for swapping models (§7.8). Prompts and zod schemas are backend-independent;
 * a backend turns a validated request into a schema-valid result or throws a `ProxyError`.
 */
export interface ModelBackend {
  readonly provider: string;
  recognizeFood(req: FoodRecognizeRequest): Promise<BackendResult<FoodRecognitionResult>>;
  parseFoodText(req: FoodParseTextRequest): Promise<BackendResult<FoodRecognitionResult>>;
  chat(req: CoachChatRequest): Promise<BackendResult<CoachChatResponse>>;
  weeklyReport(req: WeeklyReportRequest): Promise<BackendResult<WeeklyReportResponse>>;
}
