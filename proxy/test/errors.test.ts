import Anthropic from "@anthropic-ai/sdk";
import { describe, expect, it } from "vitest";

import { mapAnthropicError, ProxyError } from "../src/errors.js";

describe("mapAnthropicError", () => {
  it("maps RateLimitError to a retryable upstream_error with retryAfterSeconds", () => {
    const headers = new Headers({ "retry-after": "17" });
    const error = new Anthropic.RateLimitError(429, { type: "rate_limit_error" }, "rate limited", headers);
    const mapped = mapAnthropicError(error);
    expect(mapped.code).toBe("upstream_error");
    expect(mapped.retryable).toBe(true);
    expect(mapped.retryAfterSeconds).toBe(17);
    expect(mapped.status).toBe(502);
  });

  it("maps connection errors before generic APIError", () => {
    const mapped = mapAnthropicError(new Anthropic.APIConnectionError({ message: "ECONNRESET" }));
    expect(mapped.code).toBe("upstream_error");
    expect(mapped.retryable).toBe(true);
  });

  it("maps 5xx as retryable and 4xx as not retryable", () => {
    const server = mapAnthropicError(Anthropic.APIError.generate(529, { type: "overloaded_error" }, "overloaded", new Headers()));
    expect(server.retryable).toBe(true);
    const client = mapAnthropicError(Anthropic.APIError.generate(400, { type: "invalid_request_error" }, "bad", new Headers()));
    expect(client.retryable).toBe(false);
    expect(client.code).toBe("upstream_error");
  });

  it("passes ProxyError through and serialises the envelope", () => {
    const original = new ProxyError("upstream_refusal", "拒绝");
    expect(mapAnthropicError(original)).toBe(original);
    expect(original.toEnvelope()).toEqual({ error: { code: "upstream_refusal", message: "拒绝", retryable: false } });
    expect(new ProxyError("rate_limited", "x", { retryable: true, retryAfterSeconds: 5 }).toEnvelope()).toEqual({
      error: { code: "rate_limited", message: "x", retryable: true, retryAfterSeconds: 5 },
    });
  });
});
