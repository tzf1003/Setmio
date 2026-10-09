# 本地 goal 开发提示词

在 Mac 本地仓库根目录启动 Claude Code，把下面整段作为 goal（例如 `/goal` 后粘贴）。它假设：已 `./scripts/bootstrap.sh`、`Config/Local.xcconfig` 填好 Team ID、手边有配对了 Apple Watch 的 iPhone。

---

```
目标：把 Setmio 做到「阶段 1 MVP：自用可跑」——我每天能在 iPhone + Apple Watch 上用它：早上看到基于真实 HealthKit 数据的准备度评分，按自动规划的计划在手表上练完一次力量训练（记组、休息计时、心率），训练写回「健康」，第二天计划按表现自动调整。

开始前必读：CLAUDE.md、docs/方案.md（第 4、6、7、8 节与「验证方式」）、docs/ARCHITECTURE.md、docs/GOAL.md 末尾的「遗留 VERIFY 清单」。

硬性约束（任何时候都不能违反）：
- 所有数值（评分、重量、组数、TDEE、剂量校验）只能在 Packages/SetmioCore 里用纯函数计算并有单元测试；LLM 不产生任何数值。
- 健康数据只存本地 SwiftData（ModelContainerFactory 的 cloudKitDatabase: .none 不得改）；不接任何分析/广告 SDK。
- 减肥针相关输出一律是「与医生讨论」的建议，不得绕过 GLP1PlanValidator 的 HardBlock；本 goal 不扩展减肥针功能。
- Swift 6 strict concurrency 下零错误；不得用 @preconcurrency / @unchecked Sendable 掩盖问题，除非在注释里写明理由。
- 不确定的 Apple API 先查 SDK 头文件 / 文档再写；确认后删除对应的 // VERIFY 注释。
- 每完成一个里程碑：跑对应测试 → git commit（小步、说明清楚）→ push，CI（.github/workflows/ci.yml）必须保持全绿。

里程碑（按顺序，每个都有可检验的完成条件）：
M1 工程能在本机构建与运行
  - make generate && make build-ios && make build-watch 成功；make test-packages 与 make test-ios 全绿。
  - 在模拟器打开 App：设置里打开「演示数据」后，「今日」页显示准备度分数与分项。
M2 真机 HealthKit 接入
  - 真机首装：授权页只列出 MVP 读写类型；拒绝后再允许能恢复。
  - 「重新导入」后行数不变（hkUUID 去重有效）；60 天导入有进度显示且不卡 UI。
  - 用「健康」App 手动加一条 HRV，锁屏状态下后台投递唤醒 App 并更新评分（验证 .completeUntilFirstUserAuthentication 文件保护）。
M3 训练规划闭环（iPhone 端）
  - 首次启动引导：填档案（性别/身高/生日/目标体重）→ 选模板（推拉腿或上下肢）→ 生成中周期。
  - 「今日」页展示 ProgressionEngine 产出的计划与每个动作的决策理由，并按 ReadinessModulator 做当天调整（只改当天副本）。
  - 在 iPhone 上手动记组后，下一次同动作计划按双重渐进正确变化（加 SetmioCore 测试覆盖该路径）。
M4 Apple Watch 训练
  - 手表开始今日训练 → iPhone 进入镜像状态；点「完成」记组数秒内出现在手机；休息计时归零手表震动（后台也要震，必要时用通知兜底）。
  - 结束并评分 effort → 「健身」App 出现来自 Setmio 的「传统力量训练」，effort 与时长正确；手机端会话关联 hkWorkoutUUID。
  - 手机飞行模式下训练、恢复连接后组无重复到达；训练中强杀手表 App 可恢复。
M5 打磨与收尾
  - iPhone Live Activity 休息计时（灵动岛/锁屏），暂停/跳过回传手表。
  - 「遗留 VERIFY 清单」全部处理完（确认、修正或写明为何保留）；README 状态段更新；docs/方案.md 第 8 节标记阶段 1 完成。

工作方式：
- 每个里程碑先写/改测试再改实现；Core 逻辑放 Core，UI 只调用。
- 真机步骤需要我操作时（授权、佩戴手表、飞行模式等），把要我做的事写成编号清单后停下等我反馈，不要猜结果。
- 遇到需要产品决策的问题（交互取舍、默认值）给出推荐方案并说明理由，再等我确认。
- 全部里程碑完成、CI 全绿、真机清单逐条通过后，goal 才算完成；最后给我一份变更摘要和剩余风险。
```

---

## 遗留 VERIFY 清单

阶段 1 收尾时的处理结果（`// VERIFY` 标注只保留真正无法在 Mac 上确认的）：

| # | 位置 | 结论 |
|---|---|---|
| 1 | `TrainingEntities.swift`（`#Unique` mesocycleID+day） | **已确认并移除标注**：nil 的 mesocycleID 在 SQLite 里互不冲突，“每天一条自由计划”由 `SetmioStore.upsertPlannedSession` 保证；`ModelContainerTests.plannedSessionUniquenessWithNilMesocycle` |
| 2 | 三处可空 `@Attribute(.unique)` | **已确认并移除标注**：多行 nil 不冲突、非 nil 仍去重；`ModelContainerTests.nilUniqueValuesDoNotCollide` |
| 3 | `AppEnvironment.swift`（`@ModelActor` 线程） | **已确认并处理**：`SetmioStore` 的任务在**调用方是主 actor 时跑在主线程**（与创建线程无关），后台调用方则不在主线程。`HealthSyncService` 的 60 天聚合/评分改在 `Task.detached` 内执行；`StoreExecutorTests` 记录该行为 |
| 4 | `WorkoutWriter.swift`（effort 样本） | **改为稳妥写法并移除标注**：先 `store.save(sample)` 再 `relateWorkoutEffortSample`（若后者自带保存则幂等）。真机验证见 M4 清单“健身 App 里 effort 为 7” |
| 5 | `HapticsController.swift`（抬腕/息屏震动） | **保留**：只能在手表上观察。无论结果如何，本地通知兜底都会在休息结束时响，不会静默 |
| 6 | `ImagePreprocessor.swift`（EXIF/GPS） | **保留**：属阶段 2（拍照识别），本阶段不使用 |
| 7 | `MedicationReader.swift`（用药 API，5 处） | **保留**：属阶段 2（减肥针记录），当前为返回空的桩；本 goal 不扩展减肥针功能 |

其他需真机验证、但不对应具体代码标注的：后台投递在锁屏下能打开数据库（文件保护 `.completeUntilFirstUserAuthentication`）、镜像会话能后台拉起 iOS App、Live Activity 暂停态显示与按钮回传、手机不可达时 WatchConnectivity 兜底不重复。
