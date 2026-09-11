# ============================================================================
#  Makefile —— 本机（macOS）构建入口，无需 GitHub Actions
# ----------------------------------------------------------------------------
#  四个目标：
#    make gen    生成 ZhishengWeather.xcodeproj（xcodegen）
#    make build  生成工程并归档（未签名 Release .xcarchive）
#    make ipa    生成工程 → 归档 → 打包 build/ZhishengWeather-unsigned.ipa
#    make clean  清理 build/ 与 *.xcodeproj
#
#  附赠目标：
#    make test   在可用 iPhone 模拟器上跑单元测试
#    make help   显示本帮助
#
#  ⚠️ 语法提醒：Makefile 里每条 recipe 行**必须以 TAB 缩进**（不是空格）。
#     本文件所有命令行均以单个 TAB 开头；用编辑器改本文件时请确认
#     没有把 TAB 自动替换成空格，否则 make 会直接报
#     "missing separator"。
#
#  实现说明：核心逻辑全部收敛在 build-local.sh（含环境检查、未签名归档、
#  Payload 拼装），Makefile 只做薄封装，避免两处各写一份而行为漂移。
# ============================================================================

SHELL      := /bin/bash

# 脚本入口（相对本 Makefile 所在目录）
SCRIPT     := ./build-local.sh

PROJECT    := ZhishengWeather.xcodeproj
BUILD_DIR  := build

.PHONY: all gen build ipa test clean help

# 默认目标
all: ipa

## gen: 只生成 Xcode 工程
gen:
	@chmod +x $(SCRIPT)
	$(SCRIPT) gen

## build: 生成工程 + 未签名归档（不打包 IPA）
build:
	@chmod +x $(SCRIPT)
	$(SCRIPT) archive

## ipa: 完整链路 —— 生成工程 → 归档 → 打包未签名 IPA
ipa:
	@chmod +x $(SCRIPT)
	$(SCRIPT) ipa

## test: 生成工程 + 在可用 iPhone 模拟器上跑单元测试
test:
	@chmod +x $(SCRIPT)
	$(SCRIPT) test

## clean: 清理构建产物与生成的工程文件
clean:
	@printf '\033[0;36m[info]\033[0m  清理 %s/ 与 %s …\n' '$(BUILD_DIR)' '$(PROJECT)'
	@rm -rf $(BUILD_DIR)
	@rm -rf $(PROJECT)
	@printf '\033[0;32m[ ok ]\033[0m  已清理\n'

## help: 显示本帮助
help:
	@printf '\n用法: make [目标]\n\n目标:\n'
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -e 's/^## /  make /' -e 's/: /  —— /'
	@printf '\n产物: $(BUILD_DIR)/ZhishengWeather-unsigned.ipa\n\n'
