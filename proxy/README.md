# setmio-proxy

Setmio 的 AI 代理（方案 §7.8）。iOS 端不持有任何模型密钥；代理只做"感知与语言"（识菜、解析文字餐、教练对话、周报），所有数值（评分、渐进、TDEE、剂量校验）由 App 内的规则引擎计算。代理**不保存请求体与图片**，日志只有路由、设备哈希、耗时、状态与 token 用量。

- 运行时：[Hono](https://hono.dev)，同一份代码可跑在 Cloudflare Workers 与 Node。
- 模型：`@anthropic-ai/sdk`，`claude-opus-5-5`，结构化输出（zod schema 是契约的唯一真相）。
- 存储：设备令牌 SHA-256 与限流计数，Workers KV（生产）或内存（Node / 测试）。

## 路由

| 路由（POST，`Authorization: Bearer <deviceToken>`） | 限额 |
|---|---|
| `/v1/devices/register` `{inviteCode, deviceName, platform}` → `{deviceToken, deviceId}` | 5 / IP / 小时 |
| `/v1/food/recognize` `{imageJpegBase64, imageWidth, imageHeight, hints}` → `FoodRecognitionResult` | 60 / 设备 / 天，体积 ≤ 2 MB |
| `/v1/food/parse-text` `{text, locale, hints?}` → `FoodRecognitionResult` | 100 / 天 |
| `/v1/coach/chat` `{messages[≤40], context, locale}` → `{replyZH, suggestions, safetyFlags}` | 200 / 天 |
| `/v1/report/weekly` `{weekStart, metrics, training, nutrition, medication}` → `{titleZH, summaryZH, highlights, concerns, nextWeekFocus}` | 7 / 天 |

错误信封：`{ error: { code, message, retryable, retryAfterSeconds? } }`，`code ∈ unauthorized | rate_limited | invalid_request | image_too_large | upstream_refusal | upstream_error | backend_unavailable`。

可选请求头：`X-Setmio-Client`（客户端版本，仅日志）、`X-Setmio-Backend: claude | domestic`（仅当 `ALLOW_BACKEND_OVERRIDE=true` 时生效）。

## 本地运行（Node）

```bash
cd proxy
npm install            # 如遇 npm 的 peer 依赖解析报错，用 npm install --legacy-peer-deps
cp .dev.vars.example .dev.vars
# 填入 ANTHROPIC_API_KEY 与 INVITE_CODE；Node 模式也可直接用环境变量
set -a; source .dev.vars; set +a
npm run dev            # http://localhost:8787（内存存储，重启后设备需重新注册）
```

健康检查：`curl localhost:8787/healthz`。

## 注册一台设备

```bash
curl -s localhost:8787/v1/devices/register \
  -H 'content-type: application/json' \
  -d '{"inviteCode":"<INVITE_CODE>","deviceName":"iPhone 17","platform":"ios"}'
# → {"deviceToken":"...","deviceId":"dev_..."}
```

`deviceToken` 只返回这一次，服务端只存其 SHA-256。把它填进 App 设置页（或在 App 内输入邀请码，由 `ProxyClient.register` 自动完成并写入 Keychain）。之后的请求带 `Authorization: Bearer <deviceToken>`：

```bash
curl -s localhost:8787/v1/food/parse-text \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"text":"一碗米饭、番茄炒蛋、紫菜蛋花汤","locale":"zh-CN"}'
```

## 部署到 Cloudflare Workers

Claude 后端必须部署在大陆以外（Workers 或 HK/SG 的 Node）。

```bash
npx wrangler login
npx wrangler kv namespace create SETMIO_KV      # 把输出的 id 填到 wrangler.toml 的 kv_namespaces
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put INVITE_CODE
npm run deploy                                   # wrangler deploy
```

本地用 Workers 运行时调试：`npx wrangler dev`（读取 `.dev.vars`）。

## 开发

```bash
npm run typecheck   # tsc --noEmit
npm test            # vitest：schema 契约、鉴权、限流、拒绝映射、体积限制（后端用 FakeBackend）
```

契约变更流程（ARCHITECTURE.md §6）：先改 `src/schemas/*.ts`，更新 `test/fixtures/food_recognize_response.json`，再把同一份 fixture 复制到 `Packages/SetmioAI/Tests/SetmioAITests/Fixtures/` 并同步 `DTO/AIContracts.swift`。

## 目录

```
src/index.ts        createApp(deps) + Workers 入口（default export）
src/node.ts         @hono/node-server，端口 8787
src/env.ts          环境变量 → Config
src/deps.ts         依赖注入类型（store / backends / limits / clock / log）
src/auth.ts         bearer → SHA-256 → devices:<hash>
src/ratelimit.ts    rl:<deviceId>:<route>:<yyyy-mm-dd>
src/store.ts        KVStore：MemoryStore / WorkersKVStore
src/errors.ts       错误信封 + Anthropic SDK 错误映射
src/logging.ts      结构化日志（无请求体）
src/prompts.ts      中文系统提示词（稳定、可缓存）
src/backends/       ModelBackend 接口、ClaudeBackend、DomesticBackend（占位）
src/routes/         devices / food / coach / report
src/schemas/        zod：food / coach / report（契约真相）
test/               vitest + fixtures
```
