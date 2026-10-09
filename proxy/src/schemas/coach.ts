import { z } from "zod";

export const ChatMessageSchema = z.object({
  role: z.enum(["user", "assistant"]),
  content: z.string().min(1).max(4000),
});

/** Aggregated numbers only; no identity, no raw samples. */
export const CoachContextSchema = z.object({
  readinessScore: z.number().int().min(0).max(100).optional(),
  weightTrendKgPerWeek: z.number().optional(),
  tdee: z.number().optional(),
  proteinTargetG: z.number().optional(),
  last7DaysSessions: z.number().int().min(0).optional(),
  glp1Summary: z.string().max(500).optional(),
});

export const CoachChatRequestSchema = z.object({
  /** ≤ 20 turns = 40 messages; the first must be from the user. */
  messages: z
    .array(ChatMessageSchema)
    .min(1)
    .max(40)
    .refine((messages) => messages[0]?.role === "user", { message: "第一条消息必须来自用户" }),
  context: CoachContextSchema.default({}),
  locale: z.string().min(2).max(16).default("zh-CN"),
});

export const CoachChatResponseSchema = z.object({
  replyZH: z.string().describe("中文回复，口语、具体、不超过 200 字"),
  suggestions: z.array(z.string()).describe("0–3 条可直接执行的建议"),
  safetyFlags: z
    .array(z.string())
    .describe("触发的安全标记：medication_question / rapid_weight_loss / injury / disordered_eating / medical_symptom"),
});

export type ChatMessage = z.infer<typeof ChatMessageSchema>;
export type CoachContext = z.infer<typeof CoachContextSchema>;
export type CoachChatRequest = z.infer<typeof CoachChatRequestSchema>;
export type CoachChatResponse = z.infer<typeof CoachChatResponseSchema>;
