# Setmio 工程架构

本文是写代码时的约定手册；产品与算法背景见 `方案.md`。

## 1. 依赖图

```
                 SetmioCore（仅 Foundation，Linux 可编译）
        ┌───────────┬────┴────┬───────────┬────────────┐
   SetmioData  SetmioHealth  SetmioAI   SetmioUI
   (SwiftData) (HealthKit)  (HTTP DTO) (SwiftUI)
        └───────────┴─────────┴─────┬─────┘
   Setmio（iOS App，组合根） / SetmioWatch（Core+Health+UI） / SetmioWidgets（Core+UI）
```

规则：
- 包之间只依赖 `SetmioCore`，不横向依赖。
- `SetmioHealth` 只产出值类型（`HealthSample`、`DailyMetrics`、`LoggedSet`），不 import SwiftData。
- iOS App 的 `HealthSyncService` 是唯一把 Health → Core 引擎 → Data 串起来的地方。
- watch 不链接 `SetmioData`（训练中写本地 JSON 日志，iPhone 是事实来源）和 `SetmioAI`。
- 所有数值真相（评分、渐进、TDEE、剂量校验）都在 `SetmioCore`，纯函数 + 显式输入（`now`、`Calendar`、`TimeZone` 作参数），无设备即可单测。

## 2. 单位与时间

重量/体重 kg，能量 kcal，HRV ms，心率 bpm，睡眠 分钟，剂量 mg，食物 g。
时间：`Date`（UTC 瞬时）+ `DayKey`（本地日历日）。`DayKey.sortKey`（`yyyymmdd` 整数）用于 SwiftData 的唯一键。

## 3. 并发模型（Swift 6 strict concurrency）

| 类型 | 隔离 |
|---|---|
| Core 的所有类型 | `Sendable` 值类型，nonisolated |
| `SetmioStore`（Data） | `@ModelActor` |
| `HealthSampleImporter`、`AnchorStore`（Health） | `actor` |
| `WorkoutSessionManager`（watchOS）、`MirroringSessionReceiver`（iOS） | `@MainActor`；HealthKit delegate 回调 `nonisolated` 后 `Task { @MainActor in … }` |
| SwiftUI 视图与 `AppEnvironment` | `@MainActor` |

`@Model` 实体不跨 actor 传递；跨边界只传 Core 结构体或 `PersistentIdentifier`。包内不开启 "default MainActor isolation"。

## 4. 数据流

1. HealthKit → `HealthSampleImporter`（anchored 分页）→ `HealthSampleSink`（App 实现）→ `SetmioStore`。
2. `DailyMetricsSource` 取夜间窗口样本 → Core `DailyMetricsAggregation.aggregate` → `DailyMetrics`。
3. `ReadinessCalculator.compute` → `ReadinessScore` → `ReadinessModulator` 只改"今天"的 `PlannedSession` 副本。
4. 手表训练：`WorkoutSessionManager` 开 `HKWorkoutSession` + 镜像 → 每组先写 `WatchSessionJournal` 再 `send(.setLogged)` → iPhone `MirroringSessionReceiver` → `WorkoutMirroringHost` 幂等 upsert → `.ack`。WatchConnectivity 作兜底。
5. 训练结束：`WorkoutWriter` 写 `HKWorkout(.traditionalStrengthTraining)` + effort score。
6. AI：App → `LLMProvider`（`ClaudeProxyProvider` / `DomesticProvider`）→ `proxy/` → 模型。规则引擎的数值永远不由 LLM 产生。

## 5. 隐私底线

- 健康衍生数据只存本地 SwiftData；`ModelContainerFactory` 显式 `cloudKitDatabase: .none`。
- 发给代理的只有脱敏后的最小数据（去 EXIF 的食物照片、聚合数值）。
- 代理不保存请求体与图片。

## 6. 怎么加一个功能

1. 在 `SetmioCore` 加领域类型 / 纯函数 + 测试（`swift test --package-path Packages/SetmioCore`）。
2. 需要持久化：在 `SetmioData` 加实体 + `DomainMapping` + `SetmioStore` 方法，升级 `SetmioSchemaVn` 与迁移阶段。
3. 需要 HealthKit：在 `HealthTypes` 加类型集，在 `HealthSampleSource` 协议与 Fake 中加方法。
4. UI：共享组件进 `SetmioUI`，页面进 `Apps/Setmio/Features/<模块>/`。
5. 需要 LLM：先在 `proxy/src/schemas` 定 zod schema，再同步 `SetmioAI/DTO/AIContracts.swift` 与 fixture 测试。

## 7. 验证

- Linux / macOS：`make test-core`、`make test-ai`、`make proxy-test`。
- macOS：`make generate` → `make build-ios` / `make build-watch` → `make test-ios`。
- 真机清单见 `方案.md`「验证方式」。
