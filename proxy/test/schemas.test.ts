import { describe, expect, it } from "vitest";

import { CoachChatRequestSchema } from "../src/schemas/coach.js";
import {
  FoodRecognitionModelOutputSchema,
  FoodRecognitionResultSchema,
  FoodRecognizeRequestSchema,
} from "../src/schemas/food.js";
import { WeeklyReportRequestSchema } from "../src/schemas/report.js";
import { loadFixture } from "./fake-backend.js";

describe("schemas", () => {
  it("food_recognize_response.json is a valid FoodRecognitionResult with the exact §7.8 keys", () => {
    const raw = loadFixture<Record<string, unknown>>("food_recognize_response.json");
    const parsed = FoodRecognitionResultSchema.parse(raw);
    expect(parsed.items).toHaveLength(3);
    expect(parsed.items[0]?.nameZH).toBe("番茄炒蛋");
    expect(parsed.model).toEqual({ provider: "claude", id: "claude-opus-5-5" });

    // Round-trip must not add or drop keys (the Swift side pins the same fixture).
    expect(JSON.parse(JSON.stringify(parsed))).toEqual(raw);
    expect(Object.keys(raw).sort()).toEqual(["items", "model", "notesZH", "overallConfidence"]);
    const item = (raw["items"] as Record<string, unknown>[])[0]!;
    expect(Object.keys(item).sort()).toEqual(
      ["confidence", "kcal", "macrosBest", "nameEN", "nameZH", "needsConfirmation", "portion"].sort(),
    );
    expect(Object.keys(item["portion"] as object).sort()).toEqual(["amount", "gramsEstimate", "unit"]);
    expect(Object.keys(item["kcal"] as object).sort()).toEqual(["best", "high", "low"]);
    expect(Object.keys(item["macrosBest"] as object).sort()).toEqual(["carbsG", "fatG", "proteinG"]);
  });

  it("the model-output schema is the result minus `model`", () => {
    const raw = loadFixture<Record<string, unknown>>("food_recognize_response.json");
    const { model: _model, ...withoutModel } = raw;
    expect(FoodRecognitionModelOutputSchema.safeParse(withoutModel).success).toBe(true);
    expect(FoodRecognitionResultSchema.safeParse(withoutModel).success).toBe(false);
  });

  it("rejects malformed results", () => {
    const raw = loadFixture<{ items: Array<Record<string, unknown>> }>("food_recognize_response.json");
    delete raw.items[0]!["kcal"];
    expect(FoodRecognitionResultSchema.safeParse(raw).success).toBe(false);
  });

  it("request schemas apply defaults and limits", () => {
    const req = FoodRecognizeRequestSchema.parse({
      imageJpegBase64: "A".repeat(32),
      imageWidth: 1536,
      imageHeight: 1152,
      hints: { mealType: "lunch" },
    });
    expect(req.hints.locale).toBe("zh-CN");

    expect(FoodRecognizeRequestSchema.safeParse({ imageJpegBase64: "", imageWidth: 1, imageHeight: 1 }).success).toBe(
      false,
    );

    const chat = CoachChatRequestSchema.safeParse({
      messages: [{ role: "assistant", content: "hi" }],
      context: {},
      locale: "zh-CN",
    });
    expect(chat.success).toBe(false);

    const tooMany = CoachChatRequestSchema.safeParse({
      messages: Array.from({ length: 41 }, (_, i) => ({ role: i % 2 === 0 ? "user" : "assistant", content: "x" })),
    });
    expect(tooMany.success).toBe(false);

    const ok = CoachChatRequestSchema.parse({ messages: [{ role: "user", content: "今天练腿吗" }] });
    expect(ok.locale).toBe("zh-CN");
    expect(ok.context).toEqual({});

    expect(
      WeeklyReportRequestSchema.safeParse({
        weekStart: "2026/10/05",
        metrics: {},
        training: {},
        nutrition: {},
        medication: { adherencePct: 100, sideEffectSummary: "" },
      }).success,
    ).toBe(false);
  });
});
