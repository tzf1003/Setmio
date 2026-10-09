import { z } from "zod";

/**
 * Food contract (§7.8). The *model output* schemas carry no numeric/string constraints — Anthropic structured
 * outputs reject `minimum`/`maxLength`-style keywords — guidance lives in `.describe()` and the prompt.
 * Request schemas validate client input and may be strict.
 */

export const MealTypeSchema = z.enum(["breakfast", "lunch", "dinner", "snack"]);

export const FoodHintsSchema = z.object({
  mealType: MealTypeSchema.optional(),
  locale: z.string().min(2).max(16).default("zh-CN"),
  userNote: z.string().max(500).optional(),
  recentFoods: z.array(z.string().max(60)).max(50).optional(),
});

export const FoodRecognizeRequestSchema = z.object({
  imageJpegBase64: z.string().min(16),
  imageWidth: z.number().int().positive().max(8192),
  imageHeight: z.number().int().positive().max(8192),
  hints: FoodHintsSchema.default({ locale: "zh-CN" }),
});

export const FoodParseTextRequestSchema = z.object({
  text: z.string().min(1).max(2000),
  locale: z.string().min(2).max(16).default("zh-CN"),
  hints: FoodHintsSchema.optional(),
});

export const PortionSchema = z.object({
  amount: z.number().describe("份量数量，如 1、0.5、2"),
  unit: z.string().describe("中文单位：碗 / 份 / 个 / 块 / 杯 / 克 等"),
  gramsEstimate: z.number().describe("估算克数"),
});

export const KcalRangeSchema = z.object({
  low: z.number().describe("热量下限 kcal"),
  best: z.number().describe("最可能的热量 kcal"),
  high: z.number().describe("热量上限 kcal"),
});

export const MacrosSchema = z.object({
  proteinG: z.number(),
  carbsG: z.number(),
  fatG: z.number(),
});

export const FoodItemSchema = z.object({
  nameZH: z.string().describe("菜品中文名，一道菜一个条目，如 番茄炒蛋"),
  nameEN: z.string().describe("English name"),
  portion: PortionSchema,
  kcal: KcalRangeSchema,
  macrosBest: MacrosSchema.describe("按 best 热量对应的宏量营养素克数"),
  confidence: z.number().describe("0–1"),
  needsConfirmation: z.boolean().describe("用油量、份量或隐藏食材不确定时为 true"),
});

export const ModelInfoSchema = z.object({
  provider: z.string(),
  id: z.string(),
});

/** What the model is asked to produce (no `model` field — the backend fills it in). */
export const FoodRecognitionModelOutputSchema = z.object({
  items: z.array(FoodItemSchema),
  overallConfidence: z.number().describe("0–1，整体置信度"),
  notesZH: z.string().describe("给用户的一句话说明：估算依据、需要确认的点"),
});

/** The wire response: must match `test/fixtures/food_recognize_response.json` exactly. */
export const FoodRecognitionResultSchema = FoodRecognitionModelOutputSchema.extend({
  model: ModelInfoSchema,
});

export type FoodHints = z.infer<typeof FoodHintsSchema>;
export type FoodRecognizeRequest = z.infer<typeof FoodRecognizeRequestSchema>;
export type FoodParseTextRequest = z.infer<typeof FoodParseTextRequestSchema>;
export type FoodItem = z.infer<typeof FoodItemSchema>;
export type FoodRecognitionModelOutput = z.infer<typeof FoodRecognitionModelOutputSchema>;
export type FoodRecognitionResult = z.infer<typeof FoodRecognitionResultSchema>;
export type ModelInfo = z.infer<typeof ModelInfoSchema>;
