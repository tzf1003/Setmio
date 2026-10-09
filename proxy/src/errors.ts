import Anthropic from "@anthropic-ai/sdk";

/** Error codes of the §7.8 envelope. Mirrored by `ErrorEnvelope.Code` in SetmioAI. */
export type ErrorCode =
  | "unauthorized"
  | "rate_limited"
  | "invalid_request"
  | "image_too_large"
  | "upstream_refusal"
  | "upstream_error"
  | "backend_unavailable";

export interface ErrorEnvelope {
  error: {
    code: ErrorCode;
    message: string;
    retryable: boolean;
    retryAfterSeconds?: number;
  };
}

const STATUS: Record<ErrorCode, number> = {
  unauthorized: 401,
  rate_limited: 429,
  invalid_request: 400,
  image_too_large: 413,
  upstream_refusal: 422,
  upstream_error: 502,
  backend_unavailable: 503,
};

export class ProxyError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  readonly retryable: boolean;
  readonly retryAfterSeconds?: number;

  constructor(
    code: ErrorCode,
    message: string,
    options: { retryable?: boolean; retryAfterSeconds?: number; status?: number; cause?: unknown } = {},
  ) {
    super(message, options.cause !== undefined ? { cause: options.cause } : undefined);
    this.name = "ProxyError";
    this.code = code;
    this.status = options.status ?? STATUS[code];
    this.retryable = options.retryable ?? false;
    this.retryAfterSeconds = options.retryAfterSeconds;
  }

  toEnvelope(): ErrorEnvelope {
    const error: ErrorEnvelope["error"] = {
      code: this.code,
      message: this.message,
      retryable: this.retryable,
    };
    if (this.retryAfterSeconds !== undefined) error.retryAfterSeconds = this.retryAfterSeconds;
    return { error };
  }
}

export function isProxyError(error: unknown): error is ProxyError {
  return error instanceof ProxyError;
}

function retryAfterFromHeaders(headers: Headers | undefined): number | undefined {
  const raw = headers?.get("retry-after");
  if (!raw) return undefined;
  const seconds = Number.parseFloat(raw);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds);
  const date = Date.parse(raw);
  if (Number.isFinite(date)) return Math.max(0, Math.ceil((date - Date.now()) / 1000));
  return undefined;
}

/**
 * Maps an Anthropic SDK failure onto the envelope. Order matters: `RateLimitError` and
 * `APIConnectionError` are both subclasses of `APIError` in the TypeScript SDK.
 */
export function mapAnthropicError(error: unknown): ProxyError {
  if (error instanceof ProxyError) return error;
  if (error instanceof Anthropic.RateLimitError) {
    return new ProxyError("upstream_error", "模型服务限流，请稍后重试", {
      retryable: true,
      retryAfterSeconds: retryAfterFromHeaders(error.headers) ?? 30,
      cause: error,
    });
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return new ProxyError("upstream_error", "无法连接模型服务", { retryable: true, cause: error });
  }
  if (error instanceof Anthropic.APIError) {
    const status = typeof error.status === "number" ? error.status : undefined;
    const retryable = status === undefined || status >= 500;
    return new ProxyError("upstream_error", `模型服务错误${status ? `（${status}）` : ""}`, {
      retryable,
      cause: error,
    });
  }
  if (error instanceof Error && (error.name === "AbortError" || error.name === "TimeoutError")) {
    return new ProxyError("upstream_error", "模型响应超时", { retryable: true, cause: error });
  }
  return new ProxyError("upstream_error", "模型服务未知错误", { retryable: false, cause: error });
}
