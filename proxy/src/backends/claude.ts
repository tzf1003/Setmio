import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import type { z } from "zod";

import { CLAUDE_MODEL_ID } from "../env.js";
import { mapAnthropicError, ProxyError } from "../errors.js";
import type { TokenUsage } from "../logging.js";
import {
  COACH_SYSTEM_PROMPT,
  FOOD_PARSE_TEXT_SYSTEM_PROMPT,
  FOOD_RECOGNIZE_SYSTEM_PROMPT,
  WEEKLY_REPORT_SYSTEM_PROMPT,
} from "../prompts.js";
import { CoachChatResponseSchema, type CoachChatRequest, type CoachChatResponse } from "../schemas/coach.js";
import {
  FoodRecognitionModelOutputSchema,
  type FoodHints,
  type FoodParseTextRequest,
  type FoodRecognitionResult,
  type FoodRecognizeRequest,
} from "../schemas/food.js";
import { WeeklyReportResponseSchema, type WeeklyReportRequest, type WeeklyReportResponse } from "../schemas/report.js";
import type { BackendResult, ModelBackend } from "./types.js";

type Effort = "low" | "medium" | "high";

const MAX_TOKENS = {
  food: 4096,
  chat: 8192,
  report: 16000,
} as const;

const MEAL_TYPE_ZH: Record<string, string> = {
  breakfast: "早餐",
  lunch: "午餐",
  dinner: "晚餐",
  snack: "加餐",
};

function hintsText(hints: FoodHints | undefined): string {
  if (!hints) return "";
  const lines: string[] = [];
  if (hints.mealType) lines.push(`餐次：${MEAL_TYPE_ZH[hints.mealType] ?? hints.mealType}`);
  if (hints.userNote) lines.push(`用户备注：${hints.userNote}`);
  if (hints.recentFoods && hints.recentFoods.length > 0) {
    lines.push(`最近吃过（仅供消歧）：${hints.recentFoods.slice(0, 20).join("、")}`);
  }
  return lines.length > 0 ? `\n\n${lines.join("\n")}` : "";
}

function usageOf(message: Anthropic.Message): TokenUsage {
  const usage: TokenUsage = {
    inputTokens: message.usage.input_tokens,
    outputTokens: message.usage.output_tokens,
  };
  if (typeof message.usage.cache_read_input_tokens === "number") {
    usage.cacheReadInputTokens = message.usage.cache_read_input_tokens;
  }
  if (typeof message.usage.cache_creation_input_tokens === "number") {
    usage.cacheCreationInputTokens = message.usage.cache_creation_input_tokens;
  }
  return usage;
}

/**
 * Claude backend. Facts applied (see docs/方案.md §7.8 and the SDK reference):
 * - model `claude-opus-5-5`; thinking is always on for this model, so no `thinking` parameter is sent;
 *   depth is controlled with `output_config.effort`.
 * - structured outputs through `client.messages.parse` + `zodOutputFormat`, reading `parsed_output`.
 * - the image block comes BEFORE the text block; the stable system prompt carries `cache_control`.
 * - `stop_reason === "refusal"` → `upstream_refusal` (not retryable).
 */
export class ClaudeBackend implements ModelBackend {
  readonly provider = "claude";

  constructor(
    private readonly client: Anthropic,
    private readonly model: string = CLAUDE_MODEL_ID,
  ) {}

  private async parse<S extends z.ZodType>(options: {
    system: string;
    messages: Anthropic.MessageParam[];
    schema: S;
    effort: Effort;
    maxTokens: number;
    timeoutMs: number;
  }): Promise<{ output: z.infer<S>; usage: TokenUsage }> {
    let response;
    try {
      response = await this.client.messages.parse(
        {
          model: this.model,
          max_tokens: options.maxTokens,
          system: [{ type: "text", text: options.system, cache_control: { type: "ephemeral" } }],
          messages: options.messages,
          output_config: {
            effort: options.effort,
            format: zodOutputFormat(options.schema),
          },
        },
        { timeout: options.timeoutMs },
      );
    } catch (error) {
      throw mapAnthropicError(error);
    }

    if (response.stop_reason === "refusal") {
      throw new ProxyError("upstream_refusal", "模型拒绝处理这个请求", { retryable: false });
    }
    if (response.stop_reason === "max_tokens") {
      throw new ProxyError("upstream_error", "模型输出被截断", { retryable: true });
    }
    const output = response.parsed_output;
    if (output === null || output === undefined) {
      throw new ProxyError("upstream_error", "模型输出不符合约定格式", { retryable: true });
    }
    return { output: output as z.infer<S>, usage: usageOf(response) };
  }

  private withModel(output: z.infer<typeof FoodRecognitionModelOutputSchema>): FoodRecognitionResult {
    return { ...output, model: { provider: this.provider, id: this.model } };
  }

  async recognizeFood(req: FoodRecognizeRequest): Promise<BackendResult<FoodRecognitionResult>> {
    const text =
      `请识别这张餐食照片（${req.imageWidth}×${req.imageHeight}），按规则拆成菜品并估算。` + hintsText(req.hints);
    const { output, usage } = await this.parse({
      system: FOOD_RECOGNIZE_SYSTEM_PROMPT,
      messages: [
        {
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: "image/jpeg", data: req.imageJpegBase64 } },
            { type: "text", text },
          ],
        },
      ],
      schema: FoodRecognitionModelOutputSchema,
      effort: "low",
      maxTokens: MAX_TOKENS.food,
      timeoutMs: 55_000,
    });
    return { result: this.withModel(output), modelId: this.model, usage };
  }

  async parseFoodText(req: FoodParseTextRequest): Promise<BackendResult<FoodRecognitionResult>> {
    const { output, usage } = await this.parse({
      system: FOOD_PARSE_TEXT_SYSTEM_PROMPT,
      messages: [{ role: "user", content: `用户描述的一餐：\n${req.text}` + hintsText(req.hints) }],
      schema: FoodRecognitionModelOutputSchema,
      effort: "low",
      maxTokens: MAX_TOKENS.food,
      timeoutMs: 30_000,
    });
    return { result: this.withModel(output), modelId: this.model, usage };
  }

  async chat(req: CoachChatRequest): Promise<BackendResult<CoachChatResponse>> {
    const contextLines = Object.entries(req.context)
      .filter(([, value]) => value !== undefined && value !== null)
      .map(([key, value]) => `${key}: ${String(value)}`);
    const contextBlock =
      contextLines.length > 0 ? `【App 规则引擎的当前数值】\n${contextLines.join("\n")}` : "【App 暂无数值上下文】";

    const history = req.messages.map((m) => ({ role: m.role, content: m.content }) satisfies Anthropic.MessageParam);
    // Volatile context goes into the first user turn so the cached system prompt stays byte-stable.
    const first = history[0]!;
    history[0] = { role: "user", content: `${contextBlock}\n\n用户：${first.content}` };

    const { output, usage } = await this.parse({
      system: COACH_SYSTEM_PROMPT,
      messages: history,
      schema: CoachChatResponseSchema,
      effort: "medium",
      maxTokens: MAX_TOKENS.chat,
      timeoutMs: 45_000,
    });
    return { result: output, modelId: this.model, usage };
  }

  async weeklyReport(req: WeeklyReportRequest): Promise<BackendResult<WeeklyReportResponse>> {
    const section = (title: string, values: Record<string, number>): string => {
      const entries = Object.entries(values);
      if (entries.length === 0) return `${title}：本周没有记录`;
      return `${title}：\n${entries.map(([k, v]) => `  ${k}: ${v}`).join("\n")}`;
    };
    const text = [
      `周起始日：${req.weekStart}`,
      section("指标", req.metrics),
      section("训练", req.training),
      section("饮食", req.nutrition),
      `用药：依从率 ${req.medication.adherencePct}%；副作用：${req.medication.sideEffectSummary || "无记录"}`,
    ].join("\n\n");

    const { output, usage } = await this.parse({
      system: WEEKLY_REPORT_SYSTEM_PROMPT,
      messages: [{ role: "user", content: text }],
      schema: WeeklyReportResponseSchema,
      effort: "high",
      maxTokens: MAX_TOKENS.report,
      timeoutMs: 110_000,
    });
    return { result: output, modelId: this.model, usage };
  }
}

export function createClaudeBackend(apiKey: string, model: string = CLAUDE_MODEL_ID): ClaudeBackend {
  // The SDK retries 429/5xx twice by default; the client already retries once more, so keep it at 1 here.
  return new ClaudeBackend(new Anthropic({ apiKey, maxRetries: 1 }), model);
}
