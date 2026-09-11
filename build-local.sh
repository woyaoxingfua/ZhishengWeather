#!/usr/bin/env bash
#
# ============================================================================
#  build-local.sh —— 在 macOS 上一键构建「未签名 IPA」（不依赖 GitHub Actions）
# ============================================================================
#
#  为什么需要它：本仓库只有 `project.yml`（XcodeGen 工程定义）入库，
#  `*.xcodeproj` 不入库，且用户主力机是 Windows。在 Mac 上想自用出包时，
#  执行本脚本即可完成「生成工程 → 编译归档 → 组装 Payload → 打成 IPA」。
#
#  用法：
#    ./build-local.sh              # 等价于 make ipa
#    ./build-local.sh clean        # 清空 build/ 目录
#    ./build-local.sh gen          # 只生成 Xcode 工程
#    ./build-local.sh test         # 跑单元测试（模拟器）
#    ./build-local.sh archive      # 只归档，不打包 IPA
#
#  产物：build/ZhishengWeather-unsigned.ipa（未签名，需 Sideloadly/AltStore 重签名）
#
#  ── 两条必须遵守的脚本纪律 ─────────────────────────────────────────────────
#  1. **禁止 `| head -n1`**：`head` 读满指定行数即退出并关闭管道，上游进程
#     收到 SIGPIPE(141)，在 `set -o pipefail` 下整条管道被判为失败，脚本会
#     在「看起来一切正常」的情况下挂掉。要取第一行请用
#     `grep -m1`（由 grep 自己在首个匹配处停止）或 `sed -n '1p'`。
#  2. **禁止 `-exportArchive`**：它要求有效签名 / 已安装的 Distribution 描述
#     文件，在无证书环境必然失败。改为手工拼 `Payload/` 目录再 zip。
#
# ============================================================================

set -euo pipefail

# ── 常量 ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT_NAME="ZhishengWeather"
PROJECT_FILE="${PROJECT_NAME}.xcodeproj"
SCHEME="${PROJECT_NAME}"
SPEC="project.yml"

BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
APP_SOURCE_PATH="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"
IPA_NAME="${PROJECT_NAME}-unsigned.ipa"
IPA_PATH="${BUILD_DIR}/${IPA_NAME}"

# 未签名构建的关闭签名三元组（archive 与 test 都要用）
readonly NO_SIGN_FLAGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")

# ── 日志小件 ────────────────────────────────────────────────────────────────

info()  { printf '\033[0;36m[info]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ ok ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[0;33m[warn]\033[0m  %s\n' "$*"; }
error() { printf '\033[0;31m[fail]\033[0m  %s\n' "$*" >&2; }

# ── 环境检查 ────────────────────────────────────────────────────────────────

# 检查命令是否存在。
# - Parameter $1: 命令名。
# - Returns: 存在返回 0，否则返回 1。
has_command() {
  command -v "$1" >/dev/null 2>&1
}

# 环境自检：缺失依赖时打印清晰的 brew 安装指引后退出（非 0）。
require_environment() {
  local missing=0

  if ! has_command xcodebuild; then
    error "未找到 xcodebuild —— 本脚本必须在 macOS 上运行（并已安装 Xcode）。"
    error "  安装：打开 App Store 安装 Xcode，然后执行"
    error "        sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    missing=1
  fi

  if ! has_command xcodegen; then
    error "未找到 xcodegen —— 本仓库只维护 project.yml，需要它生成 .xcodeproj。"
    error "  安装：brew install xcodegen"
    missing=1
  fi

  if ! has_command zip; then
    error "未找到 zip 命令（打包 IPA 必需）。macOS 自带，通常不会缺失。"
    missing=1
  fi

  if ! has_command brew; then
    warn "未检测到 Homebrew。若需要安装 xcodegen，请先装 Homebrew："
    warn '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  fi

  if [ "$missing" -ne 0 ]; then
    error "环境检查未通过，已退出。请按上面的提示安装后重试。"
    exit 1
  fi

  # 若同时装了多个 Xcode，xcodebuild -version 能确认当前选中版本。
  local xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null | sed -n '1p' || true)"
  info "当前 Xcode：${xcode_version:-未知}"
}

# ── 步骤 1：生成 Xcode 工程 ─────────────────────────────────────────────────

# 依据 project.yml 重新生成 .xcodeproj（幂等，可重复执行）。
generate_project() {
  info "生成 Xcode 工程（xcodegen generate --spec ${SPEC}）…"
  xcodegen generate --spec "$SPEC"
  if [ ! -d "$PROJECT_FILE" ]; then
    error "工程生成失败：未找到 ${PROJECT_FILE}"
    exit 1
  fi
  ok "已生成 ${PROJECT_FILE}"
}

# ── 步骤 2：归档（未签名）───────────────────────────────────────────────────

# 未签名 archive 到 build/ZhishengWeather.xcarchive。
archive_app() {
  info "归档 Release（未签名）…"
  rm -rf "$ARCHIVE_PATH"
  mkdir -p "$BUILD_DIR"

  xcodebuild archive \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${NO_SIGN_FLAGS[@]}"

  if [ ! -d "$APP_SOURCE_PATH" ]; then
    error "归档产物缺失：${APP_SOURCE_PATH}"
    error "archive 是否成功？请检查上面的 xcodebuild 输出。"
    exit 1
  fi
  ok "已归档：${ARCHIVE_PATH}"
}

# ── 步骤 3：组装 Payload 并打包 IPA ─────────────────────────────────────────

# 手工构造 Payload/<App>.app 再用 zip 打包。不使用 -exportArchive（需签名）。
package_ipa() {
  info "组装 Payload 并打包 IPA…"
  rm -rf "$PAYLOAD_DIR"
  mkdir -p "$PAYLOAD_DIR"
  cp -R "$APP_SOURCE_PATH" "$PAYLOAD_DIR/"

  rm -f "$IPA_PATH"
  # 在 build/ 目录内执行，保证 zip 内的路径是 Payload/... 而不是 build/Payload/...
  ( cd "$BUILD_DIR" && zip -qry "$IPA_NAME" Payload )

  if [ ! -f "$IPA_PATH" ]; then
    error "IPA 打包失败：未生成 ${IPA_PATH}"
    exit 1
  fi
  ok "已打包：${IPA_PATH}"
}

# ── 步骤 4：单元测试（模拟器）───────────────────────────────────────────────

# 挑选一个可用的 iPhone 模拟器并跑单测。
# 纪律：这里用 `grep -m1` 而不是 `| head -n1`（原因见文件头说明）。
run_tests() {
  info "挑选可用 iPhone 模拟器…"
  local device
  device="$(xcrun simctl list devices available \
    | grep -Eom1 'iPhone [0-9]+( Pro Max| Pro| Plus| mini)?' \
    | sed -E 's/[[:space:]]+$//' || true)"

  if [ -z "$device" ]; then
    error "找不到任何可用 iPhone 模拟器。请打开 Xcode → Settings → Platforms 下载一个 iOS Simulator。"
    exit 1
  fi
  info "使用模拟器：${device}"

  mkdir -p "$BUILD_DIR"
  xcodebuild test \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,OS=latest,name=${device}" \
    -resultBundlePath "${BUILD_DIR}/TestResults.xcresult" \
    "${NO_SIGN_FLAGS[@]}"

  ok "单测通过。结果包：${BUILD_DIR}/TestResults.xcresult"
}

# ── 收尾 ────────────────────────────────────────────────────────────────────

print_artifact() {
  echo
  echo "────────────────────────────────────────────────────────────"
  ok "构建完成"
  echo "  产物：${IPA_PATH}"
  echo "  大小：$(du -h "$IPA_PATH" | sed -n '1p' | cut -f1)"
  echo
  echo "  下一步（真机安装）："
  echo "    1) 用 Sideloadly / AltStore 以个人 Apple ID 重签名 ${IPA_NAME}；"
  echo "    2) 重签名时必须保留 App Group entitlement：group.com.zhisheng.weather"
  echo "       （否则小组件会永久显示「暂无数据」且没有任何报错）；"
  echo "    3) 安装后先打开一次主 App 完成取数，小组件才会读到数据。"
  echo "────────────────────────────────────────────────────────────"
}

# ── 入口 ────────────────────────────────────────────────────────────────────

TASK="${1:-ipa}"

case "$TASK" in
  gen)
    require_environment
    generate_project
    ok "工程已就绪：${PROJECT_FILE}（可用 Xcode 打开）"
    ;;

  test)
    require_environment
    generate_project
    run_tests
    ;;

  archive)
    require_environment
    generate_project
    archive_app
    ok "归档完成：${ARCHIVE_PATH}"
    ;;

  ipa|build)
    require_environment
    generate_project
    archive_app
    package_ipa
    print_artifact
    ;;

  clean)
    info "清理构建产物…"
    rm -rf "$BUILD_DIR"
    rm -rf "$PROJECT_FILE"
    rm -rf "${BUILD_DIR}/DerivedData"
    ok "已清理 build/ 与 ${PROJECT_FILE}"
    ;;

  -h|--help|help)
    sed -n '3,26p' "${BASH_SOURCE[0]}"
    ;;

  *)
    error "未知命令：${TASK}"
    error "用法：./build-local.sh [gen|test|archive|ipa|clean|help]"
    exit 1
    ;;
esac
