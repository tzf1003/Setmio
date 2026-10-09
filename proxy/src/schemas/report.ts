import { z } from "zod";

const NumberMap = z.record(z.string().max(64), z.number());

export const WeeklyReportRequestSchema = z.object({
  /** yyyy-MM-dd */
  weekStart: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "weekStart 必须是 yyyy-MM-dd"),
  metrics: NumberMap,
  training: NumberMap,
  nutrition: NumberMap,
  medication: z.object({
    adherencePct: z.number().min(0).max(100),
    sideEffectSummary: z.string().max(500),
  }),
});

export const WeeklyReportResponseSchema = z.object({
  titleZH: z.string().describe("一句话标题"),
  summaryZH: z.string().describe("3–5 句总结"),
  highlights: z.array(z.string()).describe("做得好的 2–4 点"),
  concerns: z.array(z.string()).describe("需要注意的 0–3 点"),
  nextWeekFocus: z.array(z.string()).describe("下周 1–3 个重点"),
});

export type WeeklyReportRequest = z.infer<typeof WeeklyReportRequestSchema>;
export type WeeklyReportResponse = z.infer<typeof WeeklyReportResponseSchema>;
