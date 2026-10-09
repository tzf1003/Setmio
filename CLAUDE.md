# Setmio — 健身规划 iOS App

- 技术栈:SwiftUI + iOS 17,工程由 XcodeGen (`project.yml`) 生成,不提交 `.xcodeproj`。
- 业务逻辑放 `Packages/SetmioCore`(纯 Swift,可在 Linux 上 `swift test`);UI 放 `App/`。
- 云端容器无 Xcode,无法构建 app;构建与测试由 `.github/workflows/ci.yml` 在 macOS 上完成。
- 本地(Mac):`brew install xcodegen && xcodegen generate && open Setmio.xcodeproj`。
