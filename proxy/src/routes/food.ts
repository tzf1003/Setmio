import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";

import { bearerAuth } from "../auth.js";
import { ProxyError } from "../errors.js";
import { deviceRateLimit } from "../ratelimit.js";
import type { AppEnv, Deps } from "../deps.js";
import {
  FoodParseTextRequestSchema,
  FoodRecognitionResultSchema,
  FoodRecognizeRequestSchema,
} from "../schemas/food.js";
import { parseBody, recordUsage, selectBackend } from "./shared.js";

/** §7.8: request body ≤ 2 MB for photo recognition. */
export const MAX_IMAGE_BODY_BYTES = 2 * 1024 * 1024;

export function foodRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const auth = bearerAuth(deps.store);
  const limits = { store: deps.store, limits: deps.limits, now: deps.now };

  app.post(
    "/recognize",
    bodyLimit({
      maxSize: MAX_IMAGE_BODY_BYTES,
      onError: () => {
        throw new ProxyError("image_too_large", "照片超过 2 MB，请在设备端压缩后重试");
      },
    }),
    auth,
    deviceRateLimit("food/recognize", limits),
    async (c) => {
      c.set("route", "food/recognize");
      const body = await parseBody(c, FoodRecognizeRequestSchema);
      // Base64 expands by 4/3; guard the decoded size too so the model never sees > 1.5 MB JPEGs.
      if (body.imageJpegBase64.length * 0.75 > MAX_IMAGE_BODY_BYTES) {
        throw new ProxyError("image_too_large", "照片超过 2 MB，请在设备端压缩后重试");
      }
      const backend = selectBackend(c, deps);
      const result = await backend.recognizeFood(body);
      recordUsage(c, result);
      return c.json(FoodRecognitionResultSchema.parse(result.result), 200);
    },
  );

  app.post("/parse-text", auth, deviceRateLimit("food/parse-text", limits), async (c) => {
    c.set("route", "food/parse-text");
    const body = await parseBody(c, FoodParseTextRequestSchema);
    const backend = selectBackend(c, deps);
    const result = await backend.parseFoodText(body);
    recordUsage(c, result);
    return c.json(FoodRecognitionResultSchema.parse(result.result), 200);
  });

  return app;
}
