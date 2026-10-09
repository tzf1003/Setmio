#!/usr/bin/env bash
# One-time setup on a Mac: XcodeGen, local signing config, project generation, proxy deps.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "xcodegen not found and Homebrew is unavailable. Install from https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi

if [ ! -f Config/Local.xcconfig ]; then
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "Created Config/Local.xcconfig — set SETMIO_TEAM_ID to your Apple Developer Team ID."
fi

xcodegen generate --spec project.yml

if command -v npm >/dev/null 2>&1 && [ -f proxy/package.json ]; then
  (cd proxy && npm install)
fi

echo "Done. Open Setmio.xcodeproj, select the Setmio scheme, and run on a device paired with an Apple Watch."
