/**
 * Minimal key-value abstraction: device records (`devices:<sha256>`) and rate-limit counters
 * (`rl:<deviceId>:<route>:<yyyy-mm-dd>`). Workers KV is eventually consistent, which is acceptable
 * for a personal tool (a counter may briefly under-count across edge locations).
 */
export interface KVStore {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, ttlSeconds?: number): Promise<void>;
  delete(key: string): Promise<void>;
  /** Adds 1 and returns the new value; sets the TTL only when the key is created. */
  increment(key: string, ttlSeconds?: number): Promise<number>;
}

interface Entry {
  value: string;
  expiresAt?: number;
}

export class MemoryStore implements KVStore {
  private readonly entries = new Map<string, Entry>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  private live(key: string): Entry | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt !== undefined && entry.expiresAt <= this.now()) {
      this.entries.delete(key);
      return undefined;
    }
    return entry;
  }

  async get(key: string): Promise<string | null> {
    return this.live(key)?.value ?? null;
  }

  async put(key: string, value: string, ttlSeconds?: number): Promise<void> {
    this.entries.set(key, {
      value,
      expiresAt: ttlSeconds !== undefined ? this.now() + ttlSeconds * 1000 : undefined,
    });
  }

  async delete(key: string): Promise<void> {
    this.entries.delete(key);
  }

  async increment(key: string, ttlSeconds?: number): Promise<number> {
    const existing = this.live(key);
    const next = (existing ? Number.parseInt(existing.value, 10) || 0 : 0) + 1;
    this.entries.set(key, {
      value: String(next),
      expiresAt: existing?.expiresAt ?? (ttlSeconds !== undefined ? this.now() + ttlSeconds * 1000 : undefined),
    });
    return next;
  }

  /** Test helper. */
  clear(): void {
    this.entries.clear();
  }
}

/** Structural subset of Cloudflare's `KVNamespace` so this file compiles without the Workers type package. */
export interface WorkersKVNamespace {
  get(key: string, type: "text"): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>;
  delete(key: string): Promise<void>;
}

export class WorkersKVStore implements KVStore {
  constructor(private readonly kv: WorkersKVNamespace) {}

  get(key: string): Promise<string | null> {
    return this.kv.get(key, "text");
  }

  put(key: string, value: string, ttlSeconds?: number): Promise<void> {
    // KV requires expirationTtl ≥ 60 s.
    const expirationTtl = ttlSeconds !== undefined ? Math.max(60, Math.ceil(ttlSeconds)) : undefined;
    return this.kv.put(key, value, expirationTtl !== undefined ? { expirationTtl } : undefined);
  }

  delete(key: string): Promise<void> {
    return this.kv.delete(key);
  }

  async increment(key: string, ttlSeconds?: number): Promise<number> {
    // Read-modify-write; KV has no atomic counters. Good enough for per-device daily quotas.
    const current = Number.parseInt((await this.kv.get(key, "text")) ?? "0", 10) || 0;
    const next = current + 1;
    await this.put(key, String(next), ttlSeconds);
    return next;
  }
}
