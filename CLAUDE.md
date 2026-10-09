# Setmio — Apple Watch 原生健身规划 App

产品与算法方案：`docs/方案.md`。工程约定：`docs/ARCHITECTURE.md`。动手前先读这两份。

## 技术栈
- Swift 6（strict concurrency = complete），iOS 26 / watchOS 26，SwiftUI + SwiftData + HealthKit。
- 工程由 XcodeGen 从 `project.yml` 生成，**不提交 `.xcodeproj`**；Info.plist 与 entitlements 也由 XcodeGen 生成。
- 测试用 Swift Testing（`import Testing`、`@Test`、`#expect`）。

## 结构与边界
- `Packages/SetmioCore`：领域模型 + 全部算法（Readiness、渐进、TDEE、GLP-1 校验）。仅 Foundation，纯函数，`now`/`Calendar` 显式传入。**所有数值都在这里算，LLM 永远不产生数值。**
- `Packages/SetmioData`：SwiftData，仅本地（`cloudKitDatabase: .none`，健康数据不得进 iCloud）。
- `Packages/SetmioHealth`：HealthKit 适配；HealthKit 代码放在 `#if canImport(HealthKit)` 内，其余部分在 Linux 可测。
- `Packages/SetmioAI` + `proxy/`：LLM 走代理（Hono + `@anthropic-ai/sdk`，模型 `claude-opus-5-5`），App 内不放模型密钥。
- `Packages/SetmioUI`：共享组件与 Live Activity 属性。
- `Apps/Setmio`（iOS 组合根）、`Apps/SetmioWatch`（不链接 Data/AI）、`Apps/SetmioWidgets`。
- 包之间只依赖 SetmioCore，不横向依赖。

## 常见坑
- 在 `Identifiable` / `@Model` 类型内部，`ID<Tag>` 会被解析为 `Self.ID`，要写 `SetmioCore.ID<Tag>`。
- `@Model` 对象不跨 actor；跨边界只传 Core 结构体。
- 减肥针相关输出一律是"与医生讨论"的建议（`Advice.framing == .discussWithDoctor`），不得生成剂量计算或跳过 `GLP1PlanValidator` 的硬性规则。
- 不确定的 Apple API 用 `// VERIFY:` 标注，由 CI / 真机验证后移除。

## 命令
- Mac 本地：`./scripts/bootstrap.sh`，然后 `make build-ios` / `make build-watch` / `make test-ios`。
- 任意平台：`make test-core`、`make test-ai`、`swift test --package-path Packages/SetmioHealth`、`make proxy-test`。
- CI（`.github/workflows/ci.yml`）：Linux 跑包测试与 proxy；macOS 跑 XcodeGen + iOS/watchOS 构建 + 模拟器测试。
