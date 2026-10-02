SHELL := /bin/bash
.DEFAULT_GOAL := help
PORT ?= 4173
SWIFT_SCRATCH_PATH ?= macos/AnotherYou/.build

.PHONY: help deps build run stop update build-package check test test-agent test-swift test-scripts test-release test-updater-install website pi-source clean

help:
	@printf '%s\n' \
		'Another You 开发命令' \
		'  make deps           安装锁定的 Agent 开发依赖' \
		'  make run            构建并启动 dist/dev/Another You.app' \
		'  make stop           停止本工作区启动的开发实例' \
		'  make update         重建并重启当前本地代码' \
		'  make build          构建 Swift 开发可执行文件' \
		'  make build-package  生成开发 .app（默认 dist/macos，拒绝覆盖）' \
		'  make check          检查 TypeScript、官网 JavaScript 和 Shell 语法' \
		'  make test           运行 Agent、Swift、开发脚本和发布工具测试' \
		'  make test-agent     运行 Agent 测试' \
		'  make test-swift     运行 Swift 测试' \
		'  make test-scripts   运行工具链与隔离的开发进程生命周期测试' \
		'  make test-release   运行发布签名、元数据和双端上传流程测试' \
		'  make test-updater-install  在 macOS 临时应用中验证真实更新安装' \
		'  make website        预览官网：http://127.0.0.1:4173（PORT 可覆盖）' \
		'  make pi-source      获取锁定的 Pi 源码' \
		'  make clean          停止开发实例并清理已知构建、测试产物' \
		'' \
		'构建使用 Xcode 27+/SDK 27+；DEVELOPER_DIR 可选择 Xcode，SWIFT_SCRATCH_PATH 可隔离 build/test-swift 产物。' \
		'打包变量：OUTPUT_DIRECTORY、BUNDLE_NODE、ANOTHER_YOU_NODE。' \
		'run/update 使用固定 dist/dev；数据与 Pi 源码缓存不受 clean 影响。'

deps:
	npm ci --prefix agent-core --ignore-scripts --no-audit --no-fund

build:
	@./scripts/xcode-toolchain.sh build --package-path macos/AnotherYou --scratch-path "$(SWIFT_SCRATCH_PATH)"

run update:
	@./scripts/dev-service.sh run

stop:
	@./scripts/dev-service.sh stop

build-package:
	@./scripts/build-app.sh

check:
	npm run check --prefix agent-core
	node --check website/script.js
	node --check website/locales.js
	node --check website/i18n.js
	@for file in scripts/*.sh agent-core/scripts/*.sh; do bash -n "$$file" || exit; done

test: test-agent test-swift test-scripts test-release

test-agent:
	npm test --prefix agent-core

test-swift:
	@./scripts/xcode-toolchain.sh test --package-path macos/AnotherYou --scratch-path "$(SWIFT_SCRATCH_PATH)"

test-scripts:
	node --test website/i18n.test.cjs
	@./scripts/test-xcode-toolchain.sh
	@./scripts/test-dev-service.sh
	node --test scripts/test-prune-node-platforms.mjs scripts/test-bundled-runtime-inspection.mjs
	python3 -B scripts/test-prepare-runtime.py

test-release:
	python3 -B scripts/test-release.py
	python3 -B scripts/test-publish-release.py

test-updater-install:
	python3 -B scripts/test-updater-install.py

website:
	python3 -m http.server "$(PORT)" --bind 127.0.0.1 --directory website

pi-source:
	@./agent-core/scripts/bootstrap-pi.sh

clean:
	@./scripts/dev-service.sh clean
