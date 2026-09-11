# 枳生天气 · iOS（ZhishengWeather）

磷光终端风、无广告无账号的天气 App；主 App + WidgetKit 桌面小组件，二者通过 **App Group** 共享数据。

- 语言 / UI：Swift 5.9+ / SwiftUI（`@Observable`）
- 最低版本：iOS 17.0
- 数据源：Open-Meteo（`api.open-meteo.com/v1/forecast`，免密钥）
- 第三方依赖：**0 个**
- 工程生成：**XcodeGen**（本仓库只维护 `project.yml`，`*.xcodeproj` 不入库）

---

## 1. 目录结构

```
ZhishengWeatherIOS/
├── project.yml                  # XcodeGen 工程定义（唯一真源）
├── .github/workflows/ios.yml    # CI：生成工程 → 测试 → 出未签名 IPA
├── Config/                      # Info.plist / entitlements
├── Core/                        # ★ 主 App 与 Widget 共用编译（禁止 UIKit）
│   ├── Models/  Logic/  Storage/  Networking/  UI/
├── ZhishengWeather/             # 主 App target（入口 / 主屏 / 视图模型 / 定位）
├── ZhishengWeatherWidget/       # 小组件 target（Small / Medium）
├── ZhishengWeatherTests/        # XCTest 单元测试
└── docs/                        # 类图 / 时序图（mermaid）
```

> `Core/` 会被 **主 App 与 Widget 两个 target 同时编译**，故其内部禁止 `import UIKit`、
> 禁止使用 `UIApplication` 等仅主 App 可用的 API。

## 2. 生成工程并构建（macOS）

```bash
brew install xcodegen
xcodegen generate --spec project.yml          # 生成 ZhishengWeather.xcodeproj

# 跑单测（模拟器）
xcodebuild test \
  -project ZhishengWeather.xcodeproj \
  -scheme ZhishengWeather \
  -destination 'platform=iOS Simulator,OS=latest,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
```

## 3. 出未签名 IPA（自用分发）

无需证书。`archive` 关闭签名，再手工拼 `Payload/` 打成 IPA：

```bash
xcodebuild archive \
  -project ZhishengWeather.xcodeproj \
  -scheme ZhishengWeather \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/ZhishengWeather.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

mkdir -p build/Payload
cp -R build/ZhishengWeather.xcarchive/Products/Applications/ZhishengWeather.app build/Payload/
cd build && zip -r ZhishengWeather-unsigned.ipa Payload
```

> ⚠️ 不要使用 `xcodebuild -exportArchive`：它要求有效签名，会在无证书环境失败。

## 4. CI

`.github/workflows/ios.yml` 跑在 `macos-14`，支持 `workflow_dispatch` 手动触发与 `push`（main）。
产物 `ZhishengWeather-unsigned.ipa` 通过 `actions/upload-artifact` 上传。

## 5. 真机安装（自签 sideload）

1. 从 Actions 下载 `ZhishengWeather-unsigned.ipa`。
2. 用 **Sideloadly / AltStore / TrollStore** 等工具以个人 Apple ID 重签名后安装。
3. **首次打开主 App 后**，小组件才可能读到数据（小组件只读共享容器，不主动联网）。
   若小组件显示「暂无数据」，先打开一次主 App 触发取数写入即可。

> ⚠️ **前置条件（必读）**：小组件共享数据依赖 **App Group**，自签名时必须先满足第 6 节的
> 「App Group 自签名前置条件」。**未正确配置时不会有任何报错**，但小组件会**永久**显示
> 「暂无数据」——因为 `UserDefaults(suiteName:)` 依然返回非 nil 对象，只是落在了非共享容器里。

## 6. App Group

- App Group ID：`group.com.zhisheng.weather`（唯一定义在 `Core/Storage/AppGroup.swift`）
- 主 App 写入、Widget 只读；两个 target 的 entitlements 内容必须一致。
- 共享容器使用 `UserDefaults(suiteName:)` 存 `SharedWeatherPayload`（`snapshot` + `updatedAt`）的 JSON。

### 6.1 App Group 自签名前置条件

自签名（Sideloadly / AltStore / 手动 `codesign`）**不会**自动带上 App Group entitlement，必须逐项确认：

1. 使用**付费** Apple Developer 账号（**免费账号不支持 App Groups**）。
2. 在 *Certificates, Identifiers & Profiles → Identifiers → App Groups* 注册
   `group.com.zhisheng.weather`。
3. 在 **两个** App ID 上启用 App Groups 并勾选该 group：
   - `com.zhisheng.weather`（主 App）
   - `com.zhisheng.weather.widget`（小组件）
4. 使用的 Provisioning Profile 必须**包含**该 App Group（否则签名后 entitlement 被剥离）。
5. 重签名 / 安装时必须保留 `com.apple.security.application-groups`权利
   （Sideloadly、AltStore 或 `codesign --entitlements` 时都要确认未被丢弃）。
6. **排查**：在 App 内临时调用
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.zhisheng.weather")`，
   返回 `nil` 即 entitlement 未生效（此时小组件必然读不到数据）。

## 7. 已知限制（MVP）

- 仅「当前天气 + 逐小时 + 日高低温」，无 3/7 天预报、无多城市、无后台任务。
- 月相为平均朔望月近似算法（误差 ≤ 1 天），不引入外部星历表。
- **无 App 图标**：未引入 `Assets.xcassets`，sideload 后桌面图标为空白，不影响功能与小组件。
- **月相为八相均分分桶**（每相约 ±1/16 朔望月 ≈ ±1.85 天），非天文精确满月时刻；
  分桶边界附近的月相名可能与专业天文 App 存在 1 天量级差异。

