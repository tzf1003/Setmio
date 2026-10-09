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

阶段 0 完成：方案、五个包、iOS / watchOS / Widget 目标与 proxy 均已就绪，CI 全绿。

| 检查 | 结果 |
|---|---|
| Linux 包测试（Core / AI / Health / Data / UI） | 91 个测试通过 |
| macOS 包测试（SwiftData 存储层 + 格式化） | 17 + 7 个测试通过 |
| proxy（typecheck + vitest） | 18 个测试通过 |
| Xcode 26.6：iOS 构建（含 watch App 与 Widget）、watchOS 构建 | BUILD SUCCEEDED |
| iOS 26.5 模拟器宿主测试 | TEST SUCCEEDED |

下一步是阶段 1 MVP 的真机开发，按 [`docs/GOAL.md`](docs/GOAL.md) 在本地用 Claude Code 的 goal 推进。
