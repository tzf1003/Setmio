/**
 * Structured request log. Only route, device hash, latency, status, backend and token usage are recorded —
 * never request bodies, images, prompts or model text (§7.8 / §7.9).
 */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens?: number;
  cacheCreationInputTokens?: number;
}

export interface LogEntry {
  route: string;
  status: number;
  latencyMs: number;
  /** First 12 hex chars of the device token hash; absent for unauthenticated routes. */
  deviceHash?: string;
  backend?: string;
  model?: string;
  usage?: TokenUsage;
  errorCode?: string;
}

export type Logger = (entry: LogEntry) => void;

export const consoleLogger: Logger = (entry) => {
  console.log(JSON.stringify({ ts: new Date().toISOString(), ...entry }));
};

export const silentLogger: Logger = () => {};
