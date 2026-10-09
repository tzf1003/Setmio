XCODEGEN ?= xcodegen
PROJECT   = Setmio.xcodeproj
SIM_DEST ?= platform=iOS Simulator,name=iPhone 17

.PHONY: test-app-ui help bootstrap generate test-core test-ai test-data test-health test-ui test-packages build-ios build-watch test-ios proxy-install proxy-dev proxy-test clean

help:
	@echo "make bootstrap      - install xcodegen (brew), create Local.xcconfig, generate project, npm install proxy"
	@echo "make generate       - regenerate $(PROJECT) from project.yml"
	@echo "make test-core      - swift test for Packages/SetmioCore (works on Linux + macOS)"
	@echo "make test-ai        - swift test for Packages/SetmioAI  (works on Linux + macOS)"
	@echo "make test-packages  - swift test for all five packages (HealthKit/SwiftData parts only run on macOS)"
	@echo "make build-ios      - xcodebuild the iOS app (macOS only)"
	@echo "make build-watch    - xcodebuild the watchOS app (macOS only)"
	@echo "make test-ios       - run SetmioTests on the simulator (macOS only)"
	@echo "make test-app-ui  - simulator UI walk-through: onboarding + demo data -> readiness (screenshots in build/SetmioUI.xcresult)"
	@echo "make proxy-test     - vitest for proxy/"

bootstrap:
	./scripts/bootstrap.sh

generate:
	$(XCODEGEN) generate --spec project.yml

test-core:
	swift test --package-path Packages/SetmioCore

test-ai:
	swift test --package-path Packages/SetmioAI

test-data:
	swift test --package-path Packages/SetmioData

test-health:
	swift test --package-path Packages/SetmioHealth

test-ui:
	swift test --package-path Packages/SetmioUI

test-packages: test-core test-ai test-data test-health test-ui

build-ios: generate
	xcodebuild -project $(PROJECT) -scheme Setmio -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO

build-watch: generate
	xcodebuild -project $(PROJECT) -scheme SetmioWatch -destination 'generic/platform=watchOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO

test-ios: generate
	xcodebuild test -project $(PROJECT) -scheme Setmio -destination '$(SIM_DEST)' CODE_SIGNING_ALLOWED=NO

test-app-ui: generate
	rm -rf build/SetmioUI.xcresult
	-xcrun simctl uninstall booted com.tzf1003.setmio 2>/dev/null   # first-launch state: onboarding must appear
	xcodebuild test -project $(PROJECT) -scheme SetmioUI -destination '$(SIM_DEST)' -resultBundlePath build/SetmioUI.xcresult CODE_SIGNING_ALLOWED=NO

proxy-install:
	npm --prefix proxy install

proxy-dev:
	npm --prefix proxy run dev

proxy-test:
	npm --prefix proxy test

clean:
	rm -rf $(PROJECT) Packages/*/.build proxy/dist
