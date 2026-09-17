# 枳生天气 · iOS（ZhishengWeather）

磷光终端风、无广告无账号的天气 App；主 App + WidgetKit 桌面小组件，二者通过 **App Group** 共享数据。

- 语言 / UI：Swift 5.9+ / SwiftUI（`@Observable`）
- 最低版本：iOS 17.0
- 数据源：Open-Meteo（`api.open-meteo.com/v1/forecast`，免密钥）
- 第三方依赖：**0 个**
- 工程生成：**XcodeGen**（本仓库只维护 `project.yml`，`*.xcodeproj` 不入库）

**额度纪律（quota discipline）**：单请求合并参数（forecast/air-quality 各一条 URL 取全量）、ensemble 3 小时节流（独立域名独立慢节奏）、气候档案用户触发进入页面才请求 + 本地 5 分钟缓存。

---

## 1. 功能总览（与代码逐一对应，无虚标）

### 天气数据（单源 Open-Meteo）
- **四端点单源**：forecast（主天气）、air-quality（空气）、archive（历史/气候）、geocoding（城市搜索）、ensemble（集合预报，独立域名）。
- **气压 + 遥测补全**：海平面气压、能见度、2m 露点、总云量、10m 阵风（缺失显示 `--`，绝不显示 0 冒充）。
- **24h 逐时**预报条（按选中城市时区渲染）。
- **3 / 7 / 15 天逐日**三档切换 + 15 天独立页。
- **日出日落** + **昨日对比**（昨日整对象：温度与现象同显）。
- **月相**（八相分桶近似）+ **月出月落**（本地近似 ±10min）。
- **生活指数**（本地估算，标注「本地估算·仅供参考」）。

### 空气质量
- **六项污染物**（PM2.5 / PM10 / CO / NO₂ / SO₂ / O₃）+ **双 AQI**（美标 us_aqi 分档着色，欧标 european_aqi 辅助展示）。

### 决策优先（从"显示数据"到"告诉你该做什么"）
- **一句话天气摘要**（WeatherSummaryEngine，含「当前时段可能下雨，出门带伞」式决策文案）。
- **短时降水卡**：未来 2 小时 15 分钟粒度降水柱状序列，标注「由逐小时插值，非实况外推」（诚实标注纪律：禁止"分钟级/nowcast"措辞）；干窗整卡隐藏。
- **集合预报概率语言**（EnsembleProbabilityEngine：30 成员不确定性叙述，3h 节流，等价 4.0 倍额度）。
- **雨伞提醒**：未来 2 小时内降水起始时本地通知（干→湿才触发，雨持续不重复骚扰；固定 id 替换旧提醒；权限懒请求；设置页「提醒」开关默认开，App 本地 UserDefaults）。

### 历史 / 气候
- **历史天气近 7 日**（archive 链路，页内降级 + 重试）。
- **个人气候档案**（近 10 年同日对比：去年今日 / 近 5 年 / 近 10 年均值与差值 + mini 柱状图；用户进入页面才触发唯一一次宽范围 archive 请求 + 5 分钟本地缓存）。

### 主题 / 小组件 / 集成
- **主题三档**：深色 / 浅色 / 跟随系统（默认跟随系统；切换即整树重绘）。小组件只跟随系统深浅。
- **Widget 6 families**：桌面 Small / Medium / Large + 锁屏 accessoryCircular / accessoryRectangular / accessoryInline；城市时区随选中城市写入共享载荷（Widget 异地城市按当地时区渲染）。
- **设置页**：温度 / 风速 / 气压单位、外观三档、雨伞提醒开关、数据状态面板（各链路健康诊断）。
- **诊断**：链路失败显示故障域文案（不静默消失）、共享载荷陈旧提示。
- **静态快捷方式 + AppIntents**：主屏长按快捷方式（刷新 / 搜索城市 / 设置）+ AppIntents 快捷指令（快捷指令 App / Spotlight / 操作按钮：打开天气 / 刷新天气 / 城市搜索，复用同一路由出口）。

---

## 2. 目录结构

```
ZhishengWeatherIOS/
├── project.yml                  # XcodeGen 工程定义（唯一真源）
├── .github/workflows/ios.yml    # CI：生成工程 → 测试 → 出未签名 IPA
├── Config/                      # Info.plist / entitlements
├── Core/                        # ★ 主 App 与 Widget 共用编译（禁止 UIKit）
│   ├── Models/  Logic/  Storage/  Networking/  UI/
├── ZhishengWeather/             # 主 App target（入口 / 主屏 / 视图模型 / 定位）
├── ZhishengWeatherWidget/       # 小组件 target（6 families）
├── ZhishengWeatherTests/        # XCTest 单元测试
└── docs/                        # 类图 / 时序图（mermaid）+ 交接文档
```

> `Core/` 会被 **主 App 与 Widget 两个 target 同时编译**，故其内部禁止 `import UIKit`、
> 禁止使用 `UIApplication` 等仅主 App 可用的 API。

## 3. 生成工程并构建（macOS）

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

## 4. 出未签名 IPA（自用分发）

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

## 5. CI

`.github/workflows/ios.yml` 跑在 `macos-14`，支持 `workflow_dispatch` 手动触发与 `push`（main / ios）。
产物 `ZhishengWeather-unsigned.ipa` 通过 `actions/upload-artifact` 上传。

## 6. 真机安装（自签 sideload）

1. 从 Actions 下载 `ZhishengWeather-unsigned.ipa`。
2. 用 **Sideloadly / AltStore / TrollStore** 等工具以个人 Apple ID 重签名后安装。
3. **首次打开主 App 后**，小组件才可能读到数据（小组件只读共享容器，不主动联网）。
   若小组件显示「暂无数据」，先打开一次主 App 触发取数写入即可。

> ⚠️ **前置条件（必读）**：小组件共享数据依赖 **App Group**，自签名时必须先满足第 7 节的
> 「App Group 自签名前置条件」。**未正确配置时不会有任何报错**，但小组件会**永久**显示
> 「暂无数据」——因为 `UserDefaults(suiteName:)` 依然返回非 nil 对象，只是落在了非共享容器里。

## 7. App Group

- App Group ID：`group.com.zhisheng.weather`（唯一定义在 `Core/Storage/AppGroup.swift`）
- 主 App 写入、Widget 只读；两个 target 的 entitlements 内容必须一致。
- 共享容器使用 `UserDefaults(suiteName:)` 存 `SharedWeatherPayload`（`snapshot` + `updatedAt` + 城市时区）的 JSON。

### 7.1 App Group 自签名前置条件

自签名（Sideloadly / AltStore / 手动 `codesign`）**不会**自动带上 App Group entitlement，必须逐项确认：

1. 使用**付费** Apple Developer 账号（**免费账号不支持 App Groups**）。
2. 在 *Certificates, Identifiers & Profiles → Identifiers → App Groups* 注册
   `group.com.zhisheng.weather`。
3. 在 **两个** App ID 上启用 App Groups 并勾选该 group：
   - `com.zhisheng.weather`（主 App）
   - `com.zhisheng.weather.widget`（小组件）
4. 使用的 Provisioning Profile 必须**包含**该 App Group（否则签名后 entitlement 被剥离）。
5. 重签名 / 安装时必须保留 `com.apple.security.application-groups` 权利
   （Sideloadly、AltStore 或 `codesign --entitlements` 时都要确认未被丢弃）。
6. **排查**：在 App 内临时调用
   `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.zhisheng.weather")`，
   返回 `nil` 即 entitlement 未生效（此时小组件必然读不到数据）。

## 8. 已知限制

- 月相为平均朔望月近似算法 + 八相均分分桶（每相约 ±1/16 朔望月 ≈ ±1.85 天），非天文精确满月时刻；分桶边界附近的月相名可能与专业天文 App 存在 1 天量级差异。
- 月出月落为本地近似（±10min），极地/无事件日显示「今日无月出」式文案。
- 中国等非原生覆盖区的 15 分钟短时降水为**逐小时插值**（非实况外推），精度以卡内标注为准。
- 历史天气 / 气候档案依赖 ERA5 / 再分析资料（有 ~5 天滞后，非实况观测）。
- **无 App 图标**：未引入 `Assets.xcassets`，sideload 后桌面图标为空白，不影响功能与小组件。
- 无后台任务调度：数据刷新发生在 App 前台（冷启动 / 回前台节流 / 手动刷新 / Widget 深链强刷）。
