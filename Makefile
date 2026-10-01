SHELL := /bin/bash
.DEFAULT_GOAL := help
PORT ?= 4173

.PHONY: help deps build run stop update build-package check test test-agent test-swift test-scripts website pi-source clean

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
		'  make test           运行 Agent、Swift 和开发脚本测试' \
		'  make test-agent     运行 Agent 测试' \
		'  make test-swift     运行 Swift 测试' \
		'  make test-scripts   运行隔离的开发进程生命周期测试' \
		'  make website        预览官网：http://127.0.0.1:4173（PORT 可覆盖）' \
		'  make pi-source      获取锁定的 Pi 源码' \
		'  make clean          停止开发实例并清理已知构建、测试产物' \
		'' \
		'打包变量：OUTPUT_DIRECTORY、BUNDLE_NODE、ANOTHER_YOU_NODE。' \
		'run/update 使用固定 dist/dev；数据与 Pi 源码缓存不受 clean 影响。'

deps:
	npm ci --prefix agent-core --ignore-scripts --no-audit --no-fund

build:
	swift build --package-path macos/AnotherYou

run update:
	@./scripts/dev-service.sh run

stop:
	@./scripts/dev-service.sh stop

build-package:
	@./scripts/build-app.sh

check:
	npm run check --prefix agent-core
	node --check website/script.js
	@for file in scripts/*.sh agent-core/scripts/*.sh; do bash -n "$$file" || exit; done

test: test-agent test-swift test-scripts

test-agent:
	npm test --prefix agent-core

test-swift:
	swift test --package-path macos/AnotherYou

test-scripts:
	@./scripts/test-dev-service.sh

website:
	python3 -m http.server "$(PORT)" --bind 127.0.0.1 --directory website

pi-source:
	@./agent-core/scripts/bootstrap-pi.sh

clean:
	@./scripts/dev-service.sh clean
