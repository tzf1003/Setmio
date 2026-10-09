XCODEGEN ?= xcodegen
PROJECT   = Setmio.xcodeproj
SIM_DEST ?= platform=iOS Simulator,name=iPhone 17

.PHONY: help bootstrap generate test-core test-ai test-packages build-ios build-watch test-ios proxy-install proxy-dev proxy-test clean

help:
	@echo "make bootstrap      - install xcodegen (brew), create Local.xcconfig, generate project, npm install proxy"
	@echo "make generate       - regenerate $(PROJECT) from project.yml"
	@echo "make test-core      - swift test for Packages/SetmioCore (works on Linux + macOS)"
	@echo "make test-ai        - swift test for Packages/SetmioAI  (works on Linux + macOS)"
	@echo "make build-ios      - xcodebuild the iOS app (macOS only)"
	@echo "make build-watch    - xcodebuild the watchOS app (macOS only)"
	@echo "make test-ios       - run SetmioTests on the simulator (macOS only)"
	@echo "make proxy-test     - vitest for proxy/"

bootstrap:
	./scripts/bootstrap.sh

generate:
	$(XCODEGEN) generate --spec project.yml

test-core:
	swift test --package-path Packages/SetmioCore

test-ai:
	swift test --package-path Packages/SetmioAI

test-packages: test-core test-ai

build-ios: generate
	xcodebuild -project $(PROJECT) -scheme Setmio -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO

build-watch: generate
	xcodebuild -project $(PROJECT) -scheme SetmioWatch -destination 'generic/platform=watchOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO

test-ios: generate
	xcodebuild test -project $(PROJECT) -scheme Setmio -destination '$(SIM_DEST)'

proxy-install:
	npm --prefix proxy install

proxy-dev:
	npm --prefix proxy run dev

proxy-test:
	npm --prefix proxy test

clean:
	rm -rf $(PROJECT) Packages/*/.build proxy/dist
