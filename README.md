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

阶段 1 MVP：**代码与模拟器验收完成，等待真机清单**（[`docs/DEVICE_CHECKLIST.md`](docs/DEVICE_CHECKLIST.md)；通过后在 `docs/方案.md` §8 标记阶段 1 完成）。

| 检查 | 结果 |
|---|---|
| 包测试（Core 52 / AI 15 / Data 21 / Health 24 / UI 7） | 通过 |
| Xcode：iOS 构建（含 watch App 与 Widget）、watchOS 构建 | BUILD SUCCEEDED |
| iOS 模拟器宿主测试（含训练规划闭环） | TEST SUCCEEDED（5 个） |
| 模拟器 UI 走查 `make test-app-ui`（引导 → 演示数据 → 准备度） | 通过 |
| 真机：HealthKit / 手表训练 / Live Activity | 待验证 |

已落地：首次启动引导（档案 → 健康授权 → 模板）、按计划预填的记组、60 天导入进度条、锁屏后台投递所需的文件保护、
手表训练会话与镜像、崩溃恢复（日志回放）、休息计时暂停/继续与 Live Activity 按钮。
`// VERIFY` 的处理结果见 [`docs/GOAL.md`](docs/GOAL.md) 末尾。
