# Setmio

Apple Watch 原生的「力量训练自动调节 + 能量平衡 + 减肥针周期管理」个人教练（iOS 26 / watchOS 26，Swift 6）。

- 完整方案（产品、算法、架构、路线图）：[`docs/方案.md`](docs/方案.md)
- 工程架构与约定：[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## 仓库结构

```
project.yml            XcodeGen 工程描述（iOS App / watchOS App / Widget 扩展 / 测试）
Apps/Setmio            iOS App（组合根、功能视图、HealthKit 同步服务、镜像接收）
Apps/SetmioWatch       watchOS 独立 App（训练会话、记组、休息计时）
Apps/SetmioWidgets     iOS Widget 扩展（休息计时 Live Activity）
Packages/SetmioCore    纯 Swift 领域模型 + 算法引擎（Linux 可编译、可单测）
Packages/SetmioData    SwiftData 持久化（仅本地，不走 iCloud）
Packages/SetmioHealth  HealthKit 适配（导入、后台投递、训练会话、镜像）
Packages/SetmioAI      LLM 代理客户端（Claude / 国产模型可切换）
Packages/SetmioUI      共享 SwiftUI 组件与 Live Activity 属性
proxy/                 TypeScript 代理（Hono + @anthropic-ai/sdk），部署到 Cloudflare Workers 或 Node
Tests/                 宿主 App 的 XCTest / Swift Testing 目标
```

## 快速开始（macOS）

```bash
./scripts/bootstrap.sh      # 安装 xcodegen、生成 Config/Local.xcconfig、生成 Setmio.xcodeproj、安装 proxy 依赖
open Setmio.xcodeproj       # 选择 Setmio scheme，在已配对 Apple Watch 的 iPhone 上运行
```

把 `Config/Local.xcconfig` 里的 `SETMIO_TEAM_ID` 改成你的 Team ID。

## 测试

```bash
make test-core      # Packages/SetmioCore（Linux / macOS 均可）
make test-ai        # Packages/SetmioAI（Linux / macOS 均可）
make test-ios       # 宿主 App 测试（需要 Xcode 与模拟器）
make proxy-test     # proxy/ 的 vitest
```

## 代理（AI）

```bash
cd proxy && cp .dev.vars.example .dev.vars   # 填入 ANTHROPIC_API_KEY 与 INVITE_CODE
npm install && npm run dev                   # 本地 Node 运行；wrangler dev 可在 Workers 环境运行
```

## 状态

阶段 1 MVP：**代码完成，真机验收进行中**。逐项证据见 [`docs/DEVICE_LOG.md`](docs/DEVICE_LOG.md)，清单见 [`docs/DEVICE_CHECKLIST.md`](docs/DEVICE_CHECKLIST.md)；全部通过后才在 `docs/方案.md` §8 标记阶段 1 完成。

| 检查 | 结果 |
|---|---|
| 包测试（Core 52 / AI 15 / Data 22 / Health 25 / UI 7 / Catalogue 38） | 通过 |
| iOS 宿主测试（含训练规划闭环、数据新鲜度） | 通过（9 个） |
| iOS / watchOS 构建 | 通过 |
| CI（Linux 包测试、proxy、macOS 构建与测试） | 全绿 |
| 真机（iPhone 17 Pro Max + Apple Watch Series 11） | 清单 1、2、3、8、9 通过；5 的手机部分、6（含心率）通过；7、10、4、休息震动 待复测 |

已落地：首次启动引导、HealthKit 导入与进度、准备度评分、训练规划与手机记组、手表训练与镜像（崩溃恢复、日志回放）、休息计时与 Live Activity 按钮、打开 App 时过期数据后台刷新、**动作库**（5,632 个动作，按肌群在人体图上选择、按器械筛选）。

已知限制：App 在后台/锁屏时 HealthKit 不可读、Live Activity 不能在后台启动（平台限制，已接受）；动作库不含动画（授权不允许）。

### 许可
动作库数据（`Packages/SetmioCatalogue`）来自 openGym，按 **AGPL-3.0** 提供，署名与来源见 `Packages/SetmioCatalogue/NOTICE.md`；人体图使用 MuscleMap（MIT）。仓库目前不公开；**对外分发前必须公开对应源码**（或另行提供），并确认「设置 → 开源许可」里的源码地址有效。
