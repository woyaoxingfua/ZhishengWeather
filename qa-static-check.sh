#!/usr/bin/env bash
# ============================================================================
# qa-static-check.sh —— 枳生天气 · iOS 静态验收脚本
# ----------------------------------------------------------------------------
# 目的：在没有 Mac / 没有编译器 / 无法访问 GitHub 的 Windows 环境下，
#       用 Git Bash 对提交的仓库做一遍「能自动化的静态纪律检查」。
#
# 用法：  bash qa-static-check.sh
# 退出码：0 = 无 FAIL（可能有 WARN）；1 = 存在 FAIL
#
# 纪律（本脚本自身必须遵守）：
#   - 使用 `set -uo pipefail`，**不用 `set -e`**（要跑完全部检查再汇总）。
#   - 脚本内**禁止出现 `| head`**（在 pipefail 下 head 提前退出的 SIGPIPE 会污染管道）。
#     取首行用 `sed -n '1p'` 或 `grep -m1`。
#   - 全部检查走 run_check 包装器：即便某项命令失败（非 0 退出），
#     也只会把该项计为 FAIL/NA，绝不让整个脚本中止。
#
# 输出：每项 [PASS]/[FAIL]/[WARN]/[INFO] + 编号 + 说明；末尾汇总。
# ============================================================================

set -uo pipefail

# —— 定位到脚本所在目录，保证在任意 cwd 下都能跑 ——
cd "$(dirname "$0")" || exit 99

ROOT="$(pwd)"
readonly ROOT
readonly CORE_DIR="$ROOT/Core"
readonly WIDGET_DIR="$ROOT/ZhishengWeatherWidget"
readonly APP_DIR="$ROOT/ZhishengWeather"
readonly CFG_DIR="$ROOT/Config"
readonly TEST_DIR="$ROOT/ZhishengWeatherTests"
readonly YML="$ROOT/project.yml"
readonly CI="$ROOT/.github/workflows/ios.yml"

# —— 关闭中文乱码：强制 UTF-8 ——
export LC_ALL="${LC_ALL:-C.UTF-8}"

# —— 计数与日志 ——
PASS_N=0
FAIL_N=0
WARN_N=0
INFO_N=0

ok()   { PASS_N=$((PASS_N+1)); printf '[PASS] %s %s\n' "$1" "$2"; }
bad()  { FAIL_N=$((FAIL_N+1)); printf '[FAIL] %s %s\n' "$1" "$2"; }
warn() { WARN_N=$((WARN_N+1)); printf '[WARN] %s %s\n' "$1" "$2"; }
info() { INFO_N=$((INFO_N+1)); printf '[INFO] %s %s\n' "$1" "$2"; }

# run_check <编号> <说明> <判别函数/命令返回 0=通过>
# 用 `set +e` 包裹，禁止任何单项失败中止脚本。
run_check() {
    local id="$1"; shift
    local desc="$1"; shift
    local rc=0
    ( "$@" ) >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "$id" "$desc"
    else
        bad "$id" "$desc"
    fi
}

# 辅助：文件存在且可读
has_file() { [ -f "$1" ]; }

# ============================================================================
printf '============================================================\n'
printf ' 枳生天气 · iOS 静态验收（Windows / Git Bash，无需编译器）\n'
printf ' 仓库根：%s\n' "$ROOT"
printf '============================================================\n\n'

# ---------------------------------------------------------------------------
printf '── L1 结构与配置层 ─────────────────────────────────────────\n'
# ---------------------------------------------------------------------------

# SC-01 project.yml 存在
if [ -f "$YML" ]; then ok SC-01 "project.yml 存在"; else bad SC-01 "project.yml 缺失（工程真源丢失）"; fi

# SC-02 恰好 3 个 target，且名称正确
if [ -f "$YML" ]; then
    t_targets=$(grep -cE '^  [A-Za-z]+:$' "$YML" || true)
    has3=$(grep -qE '^  ZhishengWeather:$' "$YML" && grep -qE '^  ZhishengWeatherWidget:$' "$YML" && grep -qE '^  ZhishengWeatherTests:$' "$YML" && echo yes || echo no)
    if [ "$has3" = "yes" ]; then ok SC-02 "三个 target 名称齐全（App/Widget/Tests）"; else bad SC-02 "target 名称缺失或不匹配（应含 ZhishengWeather / ZhishengWeatherWidget / ZhishengWeatherTests）"; fi
else
    bad SC-02 "无法检查 target：project.yml 缺失"
fi

# SC-03 Core/ 被主 App 与 Widget 双挂载（一份逻辑两处复用）
if [ -f "$YML" ]; then
    core_cnt=$(grep -cE '^\s*-\s*path:\s*Core\s*$' "$YML" || true)
    if [ "${core_cnt:-0}" -ge 2 ]; then ok SC-03 "Core/ 被 2 个 target 挂载（复用成立，命中 ${core_cnt} 处）"; else bad SC-03 "Core/ 挂载次数=${core_cnt}（应 ≥2，否则主 App 与 Widget 未共享同一份逻辑）"; fi
else
    bad SC-03 "无法检查 Core 挂载：project.yml 缺失"
fi

# SC-04 测试 target 显式声明 TEST_HOST 与 BUNDLE_LOADER
if [ -f "$YML" ]; then
    if grep -qE '^\s*TEST_HOST:' "$YML" && grep -qE '^\s*BUNDLE_LOADER:' "$YML"; then
        ok SC-04 "测试 target 已显式声明 TEST_HOST / BUNDLE_LOADER"
    else
        bad SC-04 "缺 TEST_HOST 或 BUNDLE_LOADER（CI 上可能出现 'Test bundle could not be loaded'）"
    fi
else
    bad SC-04 "无法检查 TEST_HOST：project.yml 缺失"
fi

# SC-05 scheme 名与 CI -scheme 一致
if [ -f "$YML" ] && [ -f "$CI" ]; then
    scheme_ok=$(grep -qE '^  ZhishengWeather:$' "$YML" && grep -q -- '-scheme ZhishengWeather' "$CI" && echo yes || echo no)
    if [ "$scheme_ok" = "yes" ]; then ok SC-05 "scheme 名 ZhishengWeather 与 CI -scheme 一致"; else bad SC-05 "scheme 名与 CI -scheme 不一致，CI 会找不到 scheme"; fi
else
    bad SC-05 "无法检查 scheme：project.yml 或 ios.yml 缺失"
fi

# SC-06 两个 Info.plist 存在 + App 侧含定位用途说明键
app_plist="$CFG_DIR/ZhishengWeather-Info.plist"
if [ -f "$app_plist" ] && grep -q 'NSLocationWhenInUseUsageDescription' "$app_plist"; then
    ok SC-06 "App Info.plist 含 NSLocationWhenInUseUsageDescription（缺此键会闪退/无授权弹窗）"
else
    bad SC-06 "App Info.plist 缺 NSLocationWhenInUseUsageDescription"
fi

# SC-07 Widget Info.plist：必须有 NSExtensionPointIdentifier，且**禁止** NSExtensionPrincipalClass
w_plist="$CFG_DIR/ZhishengWeatherWidget-Info.plist"
if [ -f "$w_plist" ]; then
    if grep -q 'com.apple.widgetkit-extension' "$w_plist" && ! grep -q 'NSExtensionPrincipalClass' "$w_plist"; then
        ok SC-07 "Widget plist 仅含 NSExtensionPointIdentifier（无 principal class，与 Xcode 模板一致）"
    else
        bad SC-07 "Widget plist 缺少 widgetkit-extension 点标识，或错误保留了 NSExtensionPrincipalClass"
    fi
else
    bad SC-07 "Widget Info.plist 缺失"
fi

# SC-33 部署目标守护：deploymentTarget.iOS 与 IPHONEOS_DEPLOYMENT_TARGET 均不得低于 17.0
#        背景：曾发生一次事故——部署目标被误改为 16.0，而主 App 侧有两处**编译期**
#        iOS 17 依赖（WeatherViewModel 的 @Observable 宏、ZhishengWeatherApp 的双参
#        .onChange(of:){_,_ in}），#available 语法上兜不住（符号在 iOS 16 SDK 下不存在），
#        会导致 CI 必红。终态已回退到 17.0，本项防止同类事故复发。
if [ -f "$YML" ]; then
    dep_v=$(grep -E '^[[:space:]]*iOS:[[:space:]]*"' "$YML" | sed -E 's/.*"([0-9]+(\.[0-9]+)?)".*/\1/' | sed -n '1p')
    iphone_v=$(grep -E '^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET:' "$YML" | sed -E 's/.*"([0-9]+(\.[0-9]+)?)".*/\1/' | sed -n '1p')
    # 取主版本号做数值比较（>=17 通过）
    dep_major=$(echo "$dep_v" | sed -E 's/^([0-9]+).*/\1/')
    iphone_major=$(echo "$iphone_v" | sed -E 's/^([0-9]+).*/\1/')
    if [ -n "$dep_major" ] && [ "$dep_major" -ge 17 ] 2>/dev/null && \
       [ -n "$iphone_major" ] && [ "$iphone_major" -ge 17 ] 2>/dev/null; then
        ok SC-33 "部署目标守护通过：iOS=$dep_v / IPHONEOS_DEPLOYMENT_TARGET=$iphone_v（均 ≥17.0）"
    else
        bad SC-33 "部署目标被下调到 16.x 或更低（实测 iOS=$dep_v / IPHONEOS=$iphone_v）→ CI 必红：主 App 有两处编译期 iOS 17 依赖，① WeatherViewModel 的 @Observable 宏 ② ZhishengWeatherApp 的双参 .onChange(of:){_,in}；二者为「符号在 iOS 16 SDK 下不存在」，#available 语法上兜不住。请回退到 17.0。"
    fi
else
    bad SC-33 "无法检查部署目标：project.yml 缺失"
fi

# SC-34 Large Widget：supportedFamilies 必须同时含 .systemSmall / .systemMedium / .systemLarge
WB="$WIDGET_DIR/ZhishengWidgetBundle.swift"
if [ -f "$WB" ]; then
    miss=""
    for fam in '.systemSmall' '.systemMedium' '.systemLarge'; do
        sed -n '/supportedFamilies/p' "$WB" | grep -q "$fam" || miss="$miss $fam"
    done
    if [ -z "$miss" ]; then
        ok SC-34 "supportedFamilies 含 Small/Medium/Large 三档（对应真机判据 L-1）"
    else
        bad SC-34 "supportedFamilies 缺：$miss（L-1：尺寸选择器应有三档）"
    fi
else
    bad SC-34 "ZhishengWidgetBundle.swift 缺失"
fi

# SC-35 【硬约束】supportedFamilies 只增不减 —— 三项必须**全部**存在（缺任一项 = 相对
#        "Small/Medium/Large" 基线发生删除）。删除 family 会让用户已放置的该尺寸组件被
#        系统移除，故缺任一项直接 FAIL。架构师 §4.5.5 冻结为硬约束。
#        ⚠️ 注意：本项必须**只看 supportedFamilies 那一行**，不能整文件 grep ——
#        否则 `case .systemLarge:` 分支会让被删掉的 family 仍然 grep 命中（假通过）。
if [ -f "$WB" ]; then
    fam_line=$(sed -n '/supportedFamilies/p' "$WB")
    removed=""
    for fam in '.systemSmall' '.systemMedium' '.systemLarge'; do
        echo "$fam_line" | grep -q "$fam" || removed="$removed $fam"
    done
    if [ -z "$removed" ]; then
        ok SC-35 "supportedFamilies 相对基线无删除（只增不减硬约束满足）"
    else
        bad SC-35 "supportedFamilies 发生删除：$removed —— 🔴 删除 family 会让用户已放置的该尺寸组件被系统移除（PRD/ARCH §4.5.5 硬约束）。"
    fi
else
    bad SC-35 "无法检查 family 只增不减：ZhishengWidgetBundle.swift 缺失"
fi

# SC-36 switch family 含 @unknown default 分支（编译告警防线 / 未来新增 family 不崩）
#        ⚠️ 注意：必须**排除注释行**——文件头的文档注释里也写了「@unknown default」
#        （解释为什么不能省略），整文件 grep 会因注释而恒真（假通过）。
if [ -f "$WB" ]; then
    hit=$(grep -nE '^[[:space:]]*@unknown default[[:space:]]*:' "$WB" || true)
    if [ -n "$hit" ]; then
        ok SC-36 "switch family 含 @unknown default 分支（未来新增尺寸不崩、无编译告警）"
    else
        bad SC-36 "switch family 缺 @unknown default（非注释代码中未找到）—— WidgetKit 新增 family 时旧二进制行为未定义"
    fi
else
    bad SC-36 "无法检查 @unknown default：ZhishengWidgetBundle.swift 缺失"
fi

# SC-37 Large 视图与网格组件存在，且被 entry view 引用
LARGE="$WIDGET_DIR/LargeWeatherView.swift"
GRID="$WIDGET_DIR/MetricGridLayout.swift"
if [ -f "$LARGE" ] && [ -f "$GRID" ]; then
    if [ -f "$WB" ] && grep -q 'LargeWeatherView(entry:' "$WB"; then
        ok SC-37 "LargeWeatherView.swift + MetricGridLayout.swift 存在，且 LargeWeatherView 被 entry view 引用"
    else
        bad SC-37 "LargeWeatherView / MetricGridLayout 存在但未被 entry view 引用（Large 分支可能接错）"
    fi
else
    miss=""
    [ -f "$LARGE" ] || miss="$miss LargeWeatherView.swift"
    [ -f "$GRID" ] || miss="$miss MetricGridLayout.swift"
    bad SC-37 "缺文件：$miss"
fi

# SC-38 三视图的 .widgetBackground 调用点齐全（Small/Medium/Large 各一处）
#        背景统一走 WidgetBackgroundModifier 双写，任一视图漏写 = 该尺寸无背景（真机可见但静态易漂移）
if [ -f "$WIDGET_DIR/SmallWeatherView.swift" ] && [ -f "$WIDGET_DIR/MediumWeatherView.swift" ] && [ -f "$LARGE" ]; then
    miss=""
    for v in SmallWeatherView MediumWeatherView LargeWeatherView; do
        grep -q '\.widgetBackground' "$WIDGET_DIR/$v.swift" || miss="$miss $v"
    done
    if [ -z "$miss" ]; then
        ok SC-38 "Small/Medium/Large 三视图均调用 .widgetBackground（背景调用点齐全）"
    else
        bad SC-38 "以下视图缺 .widgetBackground 调用：$miss"
    fi
else
    bad SC-38 "三视图文件不全，无法检查背景调用点"
fi

# SC-39 【F-C 防线①】AppIntentConfiguration 构造点全仓（widget 目录）恰好 1 处，
#        且 StaticConfiguration 不得在非注释代码中出现（F-C-9：三 family 共用唯一构造点）
if [ -d "$WIDGET_DIR" ]; then
    intent_cnt=$(grep -rnE 'AppIntentConfiguration\(' "$WIDGET_DIR" 2>/dev/null | grep -cvE ':[0-9]+:\s*(//|\*)')
    static_cnt=$(grep -rnE 'StaticConfiguration' "$WIDGET_DIR" 2>/dev/null | grep -cvE ':[0-9]+:\s*(//|\*)')
    if [ "${intent_cnt:-0}" -eq 1 ] && [ "${static_cnt:-0}" -eq 0 ]; then
        ok SC-39 "AppIntentConfiguration 恰 1 处且无 StaticConfiguration 残留（F-C-9：三 family 共用唯一构造点）"
    else
        bad SC-39 "配置构造点异常：AppIntentConfiguration=${intent_cnt}（应恰 1），StaticConfiguration=${static_cnt}（应 0）"
    fi
else
    bad SC-39 "无法检查配置构造点：widget 目录缺失"
fi

# SC-40 【F-C 防线②】widget 目录零网络符号（配置解析在 widget 进程执行且预算极低，
#        一旦联网「编辑小组件」会卡死 —— F-C-8 / AC-C8 的静态防线）
#
#        ⚠️ 2026-09-17 补强（真实漏网）：原实现只 grep 裸网络符号
#        （URLSession/dataTask/NSURLRequest/dataTaskPublisher）。而实际发生的联网是
#        「经由 Core 的 service 类型」间接完成的 —— `WidgetCityIntent.swift` 里一句
#        `GeocodingService().search(name:)` 就能让**配置解析路径联网**，
#        而本项对 `GeocodingService` 这个名字完全无感，于是**守卫显示通过、
#        它要守的性质已经破了**（守卫自己成了 P-18 的受害者：检查与被检对象
#        共享了「联网必须出现 URLSession 字面量」这个错误假设）。
#        补强分两段：
#          SC-40a：整个 widget 目录不得出现裸网络符号（裸 session 只能活在 Core）。
#          SC-40b：**配置解析路径**额外禁止引用任何联网 service 类型。
#
#        ⚠️ 2026-09-17 二次修正（把 SC-40b 从「文件名锚定」改为「性质锚定」）：
#        SC-40b 初版只盯 `WidgetCityIntent.swift` 这**一个文件名** —— 这正是 SC-40
#        原版翻车的同一种模式：**防线锚在具名对象上，改名 / 拆分 / 搬迁就静默失效**
#        （守卫因为找不到靶子而通过）。故改为按**性质**锚定：
#          「配置解析路径」= widget 目录中**除 timeline provider 之外的每一个 .swift**。
#        逐个扫描，禁止出现任何联网 service 类型。
#
#        允许清单（**唯一**）：`WeatherProvider.swift`（timeline provider）。
#          只有它被允许联网，且**只能经 Core 的 `WidgetWeatherService`** 取数。
#          理由：AC-C8 明文只管「配置解析」；timeline 取数不在此列（那是允许的），
#          故不能对整目录一刀切 —— 但**除它以外**任何 widget 文件都不许联网，
#          不管它叫什么名字。
if [ -d "$WIDGET_DIR" ]; then
    hit=$(grep -rnE '\bURLSession\b|\bdataTask\b|\bNSURLRequest\b|\bdataTaskPublisher\b' "$WIDGET_DIR" 2>/dev/null | grep -vE ':[0-9]+:\s*(//|\*|///)' || true)
    if [ -z "$hit" ]; then
        ok SC-40a "widget 目录无裸网络符号（裸 session 只在 Core，配置解析纯本地读，F-C-8）"
    else
        bad SC-40a "widget 目录出现裸网络符号（配置解析严禁联网）：$(echo "$hit" | sed -n '1p')"
    fi
else
    bad SC-40a "无法检查 widget 网络符号：目录缺失"
fi

# SC-40b 配置解析路径禁引用联网 service（AC-C8「禁止在配置解析里发起网络请求」）
#        锚定在**性质**（除 timeline provider 外的一切 widget .swift），不锚在文件名。
#        联网 service 类型清单：凡新增网络出口都应在此登记（Core/Networking 下的 service）。
TIMELINE_PROVIDER="WeatherProvider.swift"
NET_SERVICE_RE='\bGeocodingService\b|\bWeatherService\b|\bWidgetWeatherService\b|\bEnsembleService\b|\bArchiveService\b|\bAirQualityService\b|\bClimateProfileService\b'
if [ -d "$WIDGET_DIR" ]; then
    # 目标文件被改名/搬迁时**不得静默通过**：允许清单指向的 timeline provider 缺席
    # 时报 WARN 要求复核（否则 SC-40b 的排除范围可能失真）。
    if [ ! -f "$WIDGET_DIR/$TIMELINE_PROVIDER" ]; then
        warn SC-40b "允许清单指向的 timeline provider（$TIMELINE_PROVIDER）不存在（被改名/搬迁？）—— 请复核排除范围，否则 SC-40b 可能扫错文件"
    fi
    hitb=""
    hitb_detail=""
    scanned=0
    # 遍历 widget 目录下每个 .swift，跳过 timeline provider。
    # ⚠️ 过滤注释必须用 `^[0-9]+:`（**不是** `:[0-9]+:`）：对**单个文件**做 grep -n
    #    时输出是「行号:内容」，不带文件名，故 `:[0-9]+:` 永不匹配、过滤形同虚设
    #    —— 这会让注释里的名字也被判成违规（本项初版就踩了这个坑，实测修正）。
    for f in "$WIDGET_DIR"/*.swift; do
        [ -f "$f" ] || continue
        [ "${f##*/}" = "$TIMELINE_PROVIDER" ] && continue
        scanned=$((scanned+1))
        h=$(grep -nE "$NET_SERVICE_RE" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*(//|\*|///)' || true)
        if [ -n "$h" ]; then
            hitb="yes"
            [ -z "$hitb_detail" ] && hitb_detail="${f}:$(echo "$h" | sed -n '1p')"
        fi
    done
    if [ "$scanned" -eq 0 ]; then
        warn SC-40b "widget 目录下未找到可扫描的 .swift（除 $TIMELINE_PROVIDER 外）—— SC-40b 可能扫空，请检查排除范围"
    elif [ -z "$hitb" ]; then
        ok SC-40b "配置解析路径零联网 service 引用（已扫 $scanned 个 .swift，排除 timeline provider；AC-C8）"
    else
        bad SC-40b "配置解析路径引用了联网 service，违反 AC-C8（PRD-P1:404/424，P1 起为硬禁止）：$hitb_detail —— 该处应改为在内置城市 + 容器城市里做纯本地匹配。"
    fi
else
    bad SC-40b "无法检查配置解析路径：widget 目录缺失"
fi

# SC-41 【F-C 防线③】kind 字符串逐字 = "ZhishengWeatherWidget"
#        （§4.5.5：改 kind = 系统视作全新组件，用户已放置的全部实例失效）
if [ -f "$WIDGET_DIR/ZhishengWidgetBundle.swift" ]; then
    if grep -qE 'let kind: String = "ZhishengWeatherWidget"' "$WIDGET_DIR/ZhishengWidgetBundle.swift"; then
        ok SC-41 "widget kind 逐字不变（\"ZhishengWeatherWidget\"，防存量组件失效）"
    else
        bad SC-41 "widget kind 字符串被改动 —— 系统将视作全新组件，用户已放置的全部实例失效（§4.5.5）"
    fi
else
    bad SC-41 "无法检查 kind：ZhishengWidgetBundle.swift 缺失"
fi

# ---------------------------------------------------------------------------
printf '\n── L2 源码纪律层 ───────────────────────────────────────────\n'
# ---------------------------------------------------------------------------

# SC-08 Core/ 内禁止 import UIKit
if [ -d "$CORE_DIR" ]; then
    hit=$(grep -rlE '^\s*import\s+UIKit' "$CORE_DIR" 2>/dev/null || true)
    if [ -z "$hit" ]; then ok SC-08 "Core/ 内无 import UIKit（可被 Widget 复用）"; else bad SC-08 "Core/ 内出现 import UIKit：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-08 "Core/ 目录不存在"
fi

# SC-09 Core/ 内禁止使用 UIApplication
if [ -d "$CORE_DIR" ]; then
    hit=$(grep -rnE '\bUIApplication\b' "$CORE_DIR" 2>/dev/null | grep -vE '^\s*[^:]+:[0-9]+:\s*(//|\*|/\*)' || true)
    if [ -z "$hit" ]; then ok SC-09 "Core/ 内无 UIApplication 使用"; else bad SC-09 "Core/ 内出现 UIApplication：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-09 "Core/ 目录不存在"
fi

# SC-10 全仓（源码，排除注释）禁止 try! / fatalError / as! 强制转换
SRC_DIRS="$CORE_DIR $APP_DIR $WIDGET_DIR"
if [ -d "$CORE_DIR" ]; then
    hit=$(grep -rnE '\btry!|\bfatalError\s*\(|\bas!\s' $SRC_DIRS 2>/dev/null | grep -vE ':[0-9]+:\s*(//|\*|/\*)' || true)
    if [ -z "$hit" ]; then ok SC-10 "源码内无 try! / fatalError / as!（仅允许注释提及）"; else bad SC-10 "源码内出现强制失败 API：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-10 "无法扫描源码目录"
fi

# SC-11 Core/ 逻辑与网络层禁止内部调用 Date()（须由参数注入）
if [ -d "$CORE_DIR" ]; then
    hit=$(grep -rnE '\bDate\(\)' "$CORE_DIR" 2>/dev/null | grep -vE ':[0-9]+:\s*(//|\*|/\*)' || true)
    if [ -z "$hit" ]; then ok SC-11 "Core/ 内无非注释的 Date()（时间可注入，可测）"; else bad SC-11 "Core/ 内出现非注释 Date()：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-11 "Core/ 目录不存在"
fi

# SC-12 Core/ 的 UI 组件不得 import SwiftUI 之外的主 App 专属框架（如 UIKit 的封装）
#      这里做信息型核查：列出 Core/ 内所有 import，人工确认无 UIKit/AppKit
if [ -d "$CORE_DIR" ]; then
    imports=$(grep -rhoE '^import\s+[A-Za-z]+' "$CORE_DIR" 2>/dev/null | sort -u | tr '\n' ' ')
    case "$imports" in
        *UIKit*|*AppKit*|*Cocoa*)
            bad SC-12 "Core/ import 中含主 App 专属框架：$imports" ;;
        *)
            ok SC-12 "Core/ import 集合仅含可复用框架：$imports" ;;
    esac
else
    bad SC-12 "Core/ 目录不存在"
fi

# ---------------------------------------------------------------------------
printf '\n── L3 数据契约层 ───────────────────────────────────────────\n'
# ---------------------------------------------------------------------------

EP="$CORE_DIR/Networking/OpenMeteoEndpoint.swift"
RESP="$CORE_DIR/Models/OpenMeteoResponse.swift"

# SC-13 端点声明 wind_speed_unit=ms（否则风速被放大 3.6 倍）
if [ -f "$EP" ]; then
    if grep -qE '"wind_speed_unit"[[:space:]]*,[[:space:]]*value:[[:space:]]*"ms"' "$EP"; then
        ok SC-13 "端点显式声明 wind_speed_unit=ms（防止风速放大 3.6 倍）"
    else
        bad SC-13 "端点未声明 wind_speed_unit=ms —— 风速会以 km/h 返回，与 m/s 模型不符"
    fi
else
    bad SC-13 "OpenMeteoEndpoint.swift 缺失"
fi

# SC-14 端点声明 timeformat=unixtime（否则 Int 时间字段解码直接失败）
if [ -f "$EP" ]; then
    if grep -qE '"timeformat"[[:space:]]*,[[:space:]]*value:[[:space:]]*"unixtime"' "$EP"; then
        ok SC-14 "端点声明 timeformat=unixtime（与 Int 时间字段一致）"
    else
        bad SC-14 "端点未声明 timeformat=unixtime —— 时间字段为字符串，Codable 解码会失败"
    fi
else
    bad SC-14 "OpenMeteoEndpoint.swift 缺失"
fi

# SC-15 端点声明 timezone=auto
if [ -f "$EP" ]; then
    if grep -qE '"timezone"[[:space:]]*,[[:space:]]*value:[[:space:]]*"auto"' "$EP"; then
        ok SC-15 "端点声明 timezone=auto（跟随坐标时区）"
    else
        bad SC-15 "端点未声明 timezone=auto"
    fi
else
    bad SC-15 "OpenMeteoEndpoint.swift 缺失"
fi

# SC-16 current 请求字段 ↔ Current 模型字段 逐一对应（静默错配高发区）
if [ -f "$EP" ] && [ -f "$RESP" ]; then
    missing=""
    cur_block=$(sed -n '/static let currentFields/,/\.joined/p' "$EP")
    for fld in temperature_2m relative_humidity_2m apparent_temperature weather_code wind_speed_10m wind_direction_10m is_day; do
        echo "$cur_block" | grep -q "\"$fld\"" || missing="$missing $fld"
    done
    if [ -z "$missing" ]; then ok SC-16 "current 请求字段与模型字段一一对应（7 字段齐全）"; else bad SC-16 "current 请求字段缺：$missing（解码会因缺键抛错）"; fi
else
    bad SC-16 "无法做字段对照：端点或模型文件缺失"
fi

# SC-17 hourly 请求字段 ↔ Hourly 模型字段对应
if [ -f "$EP" ] && [ -f "$RESP" ]; then
    missing=""
    hb=$(sed -n '/static let hourlyFields/,/\.joined/p' "$EP")
    for fld in temperature_2m weather_code; do
        echo "$hb" | grep -q "\"$fld\"" || missing="$missing $fld"
    done
    if [ -z "$missing" ]; then ok SC-17 "hourly 请求字段与模型字段一一对应"; else bad SC-17 "hourly 请求字段缺：$missing"; fi
else
    bad SC-17 "无法做字段对照"
fi

# SC-18 daily 请求字段 ↔ Daily 模型字段对应（v1.1 高低温来源）
if [ -f "$EP" ] && [ -f "$RESP" ]; then
    missing=""
    db=$(sed -n '/static let dailyFields/,/\.joined/p' "$EP")
    for fld in temperature_2m_max temperature_2m_min; do
        echo "$db" | grep -q "\"$fld\"" || missing="$missing $fld"
    done
    if [ -z "$missing" ]; then ok SC-18 "daily 请求字段与模型字段一一对应（高/低温来源）"; else bad SC-18 "daily 请求字段缺：$missing"; fi
else
    bad SC-18 "无法做字段对照"
fi

# ---------------------------------------------------------------------------
printf '\n── L4 App Group 契约层 ─────────────────────────────────────\n'
# ---------------------------------------------------------------------------

AG="$CORE_DIR/Storage/AppGroup.swift"
E1="$CFG_DIR/ZhishengWeather.entitlements"
E2="$CFG_DIR/ZhishengWeatherWidget.entitlements"
GROUP="group.com.zhisheng.weather"

# SC-19 AppGroup.swift 定义唯一真源，且 group id 正确
if [ -f "$AG" ]; then
    if grep -q "\"$GROUP\"" "$AG"; then ok SC-19 "AppGroup.identifier 唯一真源 = $GROUP"; else bad SC-19 "AppGroup.identifier 不等于 $GROUP"; fi
else
    bad SC-19 "Core/Storage/AppGroup.swift 缺失（App Group 契约无唯一真源）"
fi

# SC-20 两个 entitlements 的 group 字符串完全一致
if [ -f "$E1" ] && [ -f "$E2" ]; then
    if grep -q "$GROUP" "$E1" && grep -q "$GROUP" "$E2"; then ok SC-20 "主 App 与 Widget 两个 entitlements 的 App Group 字符串一致"; else bad SC-20 "两个 entitlements 的 App Group 不一致（Widget 永远读不到数据）"; fi
else
    bad SC-20 "entitlements 文件缺失"
fi

# SC-21 散落字符串检查：Core/ 内除 AppGroup.swift 外不得硬编码 group id 字面量
if [ -d "$CORE_DIR" ]; then
    hit=$(grep -rn "$GROUP" "$CORE_DIR" 2>/dev/null | grep -v 'Storage/AppGroup.swift' || true)
    if [ -z "$hit" ]; then ok SC-21 "Core/ 内 group id 字面量未散落（仅 AppGroup.swift 一处）"; else warn SC-21 "Core/ 内多处硬编码 group id：$(echo "$hit" | sed -n '1p')"; fi
else
    warn SC-21 "Core/ 缺失，跳过散落字符串检查"
fi

# ---------------------------------------------------------------------------
printf '\n── L5 CI 脚本层 ────────────────────────────────────────────\n'
# ---------------------------------------------------------------------------

# SC-22 CI 工作流文件存在
if [ -f "$CI" ]; then ok SC-22 ".github/workflows/ios.yml 存在"; else bad SC-22 "CI 工作流缺失"; fi

# SC-23 核心纪律：CI 脚本中不得出现 `| head`（本项用固定字符串匹配，不自我命中）
#        模式：管道符 + 任意空白 + head 单词。本文件的写法把竖线与 head 拼成变量，
#        且本项只对 $CI 生效，故不会扫描到 qa-static-check.sh 自身。
if [ -f "$CI" ]; then
    PIPE='\|'
    pat="${PIPE}[[:space:]]*head\b"
    hit=$(grep -nE "$pat" "$CI" || true)
    if [ -z "$hit" ]; then ok SC-23 "CI 中无 '| head'（规避 pipefail 下的 SIGPIPE 141）"; else bad SC-23 "CI 中出现 '| head'，pipefail 下会导致 step 随机挂掉：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-23 "无法检查：ios.yml 缺失"
fi

# SC-24 destination 锁 OS=latest（防运行时低于 17.0 匹配失败）
if [ -f "$CI" ]; then
    if grep -q 'OS=latest' "$CI"; then ok SC-24 "CI destination 已锁 OS=latest"; else bad SC-24 "CI destination 未锁 OS=latest（runner 运行时低于 iOS 17.0 时会匹配失败）"; fi
else
    bad SC-24 "无法检查：ios.yml 缺失"
fi

# SC-25 测试补 -resultBundlePath（否则测试结果 artifact 永远为空）
if [ -f "$CI" ]; then
    if grep -q 'resultBundlePath' "$CI"; then ok SC-25 "xcodebuild test 带 -resultBundlePath（结果可上传）"; else bad SC-25 "缺 -resultBundlePath，测试结果 artifact 永远匹配不到文件"; fi
else
    bad SC-25 "无法检查：ios.yml 缺失"
fi

# SC-26 模拟器选择：无可用机型时不得静默回落硬编码机型（应显式报错退出）
if [ -f "$CI" ]; then
    seg=$(sed -n '/Pick an available iPhone simulator/,/Run unit tests/p' "$CI")
    if echo "$seg" | grep -q '::error::'; then
        ok SC-26 "无可用模拟器时显式 ::error:: 退出（无静默回落）"
    else
        warn SC-26 "模拟器选择段未见显式 ::error::，可能静默回落到硬编码机型"
    fi
else
    warn SC-26 "无法检查：ios.yml 缺失"
fi

# SC-27 artifact 上传路径与产物名一致（IPA）
if [ -f "$CI" ]; then
    if grep -q 'ZhishengWeather-unsigned.ipa' "$CI"; then ok SC-27 "IPA artifact 路径与打包产物名一致"; else warn SC-27 "未找到 ZhishengWeather-unsigned.ipa 上传路径"; fi
else
    warn SC-27 "无法检查：ios.yml 缺失"
fi

# SC-28 测试结果上传步骤为 if: always()（测试失败也要留证据）
if [ -f "$CI" ]; then
    seg=$(sed -n '/Upload test results/,$p' "$CI")
    if echo "$seg" | grep -q 'if: always()'; then ok SC-28 "测试结果上传步骤带 if: always()（失败也留证据）"; else warn SC-28 "测试结果上传未带 if: always()，测试失败时可能丢证据"; fi
else
    warn SC-28 "无法检查：ios.yml 缺失"
fi

# ---------------------------------------------------------------------------
printf '\n── L6 测试层 ───────────────────────────────────────────────\n'
# ---------------------------------------------------------------------------

# SC-29 测试文件数 ≥ 5
if [ -d "$TEST_DIR" ]; then
    nfiles=$(find "$TEST_DIR" -maxdepth 1 -name '*.swift' -type f | wc -l | tr -d ' ')
    if [ "${nfiles:-0}" -ge 5 ]; then ok SC-29 "测试文件数 = ${nfiles}（≥5）"; else bad SC-29 "测试文件数 = ${nfiles}（偏少）"; fi
else
    bad SC-29 "ZhishengWeatherTests/ 目录缺失"
fi

# SC-30 测试用例总数（func test*）≥ 60，并逐文件输出
if [ -d "$TEST_DIR" ]; then
    total=0
    for f in "$TEST_DIR"/*.swift; do
        [ -f "$f" ] || continue
        c=$(grep -cE '^\s*func test' "$f" || true)
        total=$((total + ${c:-0}))
        info "-" "  $(basename "$f")：${c:-0} 条用例"
    done
    if [ "${total:-0}" -ge 60 ]; then ok SC-30 "测试用例总数 = ${total}（≥60）"; else warn SC-30 "测试用例总数 = ${total}（偏少，建议 ≥60）"; fi
else
    bad SC-30 "无法统计用例：测试目录缺失"
fi

# SC-31 测试代码内不得有 try! / 强制解包 as!/fatalError
if [ -d "$TEST_DIR" ]; then
    hit=$(grep -rnE '\btry!|\bfatalError\s*\(|\bas!\s' "$TEST_DIR" 2>/dev/null | grep -vE ':[0-9]+:\s*(//|\*|/\*)' || true)
    if [ -z "$hit" ]; then ok SC-31 "测试代码内无 try! / fatalError / as!"; else bad SC-31 "测试代码内出现强制失败 API：$(echo "$hit" | sed -n '1p')"; fi
else
    bad SC-31 "无法扫描测试目录"
fi

# SC-32 关键被测类型均有对应测试文件（命名覆盖）
if [ -d "$TEST_DIR" ]; then
    miss=""
    for t in MoonCalculator WMOCodeMapper OpenMeteoEndpoint OpenMeteoMapper AppGroupStore; do
        find "$TEST_DIR" -maxdepth 1 -name "${t}Tests.swift" -type f | grep -q . || miss="$miss $t"
    done
    if [ -z "$miss" ]; then ok SC-32 "五类关键被测对象均有同名测试文件"; else warn SC-32 "缺对应测试文件：$miss"; fi
else
    warn SC-32 "无法检查测试覆盖映射"
fi

# ============================================================================
printf '\n============================================================\n'
printf ' 汇总：总计 %d 项，PASS %d，FAIL %d，WARN %d（另 INFO %d 条）\n' \
    "$((PASS_N+FAIL_N+WARN_N))" "$PASS_N" "$FAIL_N" "$WARN_N" "$INFO_N"
printf '============================================================\n'

printf '\n提醒：以下三项静态检查 100%% 抓不到，必须真机验证——\n'
printf '  1) Widget 能否被添加到桌面（长按桌面 → 添加组件 → 搜「枳生天气」）\n'
printf '  2) App Group 是否真通（主 App 取数后，小组件是否显示真实数据）\n'
printf '  3) 真机定位是否弹窗并返回真实坐标\n'
printf '\nLarge 组件真机判据（架构师 §4.5.1 冻结编号，当前可执行）：\n'
printf '  L-1 尺寸选择器三档 / L-2 Large 正常渲染 / L-3 与 Medium 数据一致\n'
printf '  L-4 下拉刷新三者同更 / L-5 编辑应出现城市配置项 / L-6 大字号不溢出 / L-7 高对比度可读\n'
printf '  L-8~L-11 逐日 3 列（F-A 已落地，现可执行；L-5 期望值已随 F-C 反转）\n'

if [ "$FAIL_N" -gt 0 ]; then
    printf '\n静态验收结果：FAIL %d 项 —— 请修复后重跑。\n' "$FAIL_N"
    exit 1
fi

printf '\n静态验收结果：全部 PASS（WARN %d 项需人工确认）。\n' "$WARN_N"
exit 0
