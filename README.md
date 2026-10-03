# 枳生天气 · iOS

> 磷光终端风的天气 App。无广告、无账号、无埋点，零第三方依赖。

![平台](https://img.shields.io/badge/iOS-17.0%2B-3BA0F5?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.9-FF6F1E?style=flat-square)
![依赖](https://img.shields.io/badge/dependencies-0-31C9DB?style=flat-square)
![许可](https://img.shields.io/badge/license-MIT-31C9DB?style=flat-square)

本工程是 Android 开源项目 [zhishengplus/ZhishengWeather](https://github.com/zhishengplus/ZhishengWeather)
的 iOS 重写版（Swift + SwiftUI 全新实现，不是代码移植）。

---

## 它能干什么

**实况**：气温、体感、湿度、风速风向、气压、能见度、露点、云量、阵风、降水量、降雪、UV 指数等 18 项。

**逐时 24 小时**：气温、天气码、降水概率、降水量、风速、阵风、体感、风向，
配逐时降水图与风力图。

**逐日 3 / 7 / 15 天**：高低温、天气码、降水概率、降水与降雪合计、最大风速与阵风、
主导风向、昼长、日照时数、体感高低温。

**日出日落 + 昼长 + 距日落倒计时**，月相与月出月落，昨日对比。

**空气质量 24 小时趋势**，短时降水卡（15 分钟粒度、逐柱概率）。

**多数据源**：多个数据源并行参考（见「数据来源」）。某个源不好就自动退场，
UI 会标注某个字段实际来自哪个源——不说谎。

**一句话决策**：不大篇幅铺数据，优先给「当前时段可能下雨，出门带伞」这种结论。

<details>
<summary>完整字段清单（展开看细节）</summary>

- **实况 18 项**：气温 / 体感 / 湿度 / 天气码 / 风速风向 / 昼夜 / 气压 / 能见度 /
  露点 / 云量 / 阵风 / 降水量 / 雨 / 阵雨 / 降雪 / UV 指数
- **逐时 8 项序列**（24 小时，按城市当地时区渲染）：气温 / 天气码 / 降水概率 /
  降水量 / 风速 / 阵风 / 体感温度 / 风向
- **逐日 17 项**：高低温 / 天气码 / 降水概率 / 降水合计 / 雨合计 / 降雪合计 /
  最大风速 / 最大阵风 / 主导风向 / 昼长 / 日照时数 / 体感高低温
- **三档切换**：3 / 7 / 15 天，另有 15 天独立页
- 月相、月出月落、昨日对比、决策摘要、雨伞提醒（本地通知）

</details>

---

## 下载与安装

CI 每次构建会产出**未签名的 IPA**，需要用 Sideloadly / AltStore / TrollStore 之类的工具
用自己的 Apple ID 重签后安装。**没有上架 App Store，也不需要付费开发者账号。**

1. 到 [Actions 页面](https://github.com/woyaoxingfua/ZhishengWeather/actions)
   下载产物 `ZhishengWeather-unsigned-ipa`（或从源码自行构建，见「开发者」一节）。
2. 用上述工具重签安装。
3. **打开一次主 App** —— 触发首次取数。
4. 想知道装的是不是最新包？进 **设置 → 关于**（或设置页底部的版本行），
   版本号形如 `0.1.0 (137)`，**括号里是构建号，每次 CI 构建都会变**。
   侧载不会刷新桌面图标与名称缓存，只看桌面分不出新旧，**以这个构建号为准**。

### 关于桌面小组件

小组件**目前无法在本项目的分发渠道上正常工作**（重签侧载）。它不再作为功能卖点，
细节与已知情况见文末「已知问题」一节。

---

## 隐私

这几件事是刻意的选择，不是"还没做"：

- **不要账号**，没有登录流程，没有用户身份。
- **不采集、不上报**：没有分析 SDK、没有埋点、没有崩溃上报。
- **只连天气接口**。代码里出现的全部外网域名：

  | 域名 | 用途 |
  |---|---|
  | `api.open-meteo.com` | 主源：实况 / 逐时 / 逐日 |
  | `air-quality-api.open-meteo.com` | 空气质量 |
  | `archive-api.open-meteo.com` | 历史 / 气候档案 |
  | `ensemble-api.open-meteo.com` | 集合预报（不确定性） |
  | `geocoding-api.open-meteo.com` | 城市搜索 |
  | `api.sunrise-sunset.org` | 日出日落 / 昼长 |
  | `api.met.no` | MET Norway（交叉校验） |

- **定位权限**（`NSLocationWhenInUse`）**可以不给**。拒绝后会回退到默认城市（北京），
  你自己搜城市一样能用。定位只用于确定当前位置，不存储、不上传。

---

## 数据来源

| 源 | 角色 | 提供 | 凭据 |
|---|---|---|---|
| **Open-Meteo forecast** | 主源 | 实况 / 逐时 / 逐日 / 短时降水 | 免 Key |
| Open-Meteo air-quality | 辅助 | 空气质量 | 免 Key |
| sunrise-sunset.org | 辅助 | 日出 / 日落 / 昼长 | 免 Key |
| **MET Norway** | 辅助 | 气温 / 气压 / 湿度 / 云量 / 风速 / 风向 | 免 Key |

四条设计约定：

- **多源不是"取平均"**：主源某个字段有值，**绝不被备源覆盖**；也**绝不融合**——
  每个字段只"选择"一个来源，结构上不存在平均路径。
- **某源不可靠会自动退场**：连续缺失或 `401/403` 摘除，`429` 冷却 10 分钟。主源不参与自动摘除。
- **用量克制**：给源加字段不增加请求次数（同一条 URL 合并参数）； ensemble 走独立域名、
  3 小时节流；气候档案进页面才请求 + 本地缓存。
- **扩建一个新的源**成本低（四个文件 + 一处登记），详见 `docs/handover/ARCH-zhisheng-ios-multi-source.md`。

---

## 已知限制

如实列出，不掩：

- **逐日预报最多 15 天**：服务端在 `forecast_days=16` 时，第 16 天只填充到下午、
  其余为 `null`（不是异常，是它的明文行为）。所以**接口取 16 天，UI 只承诺 15 天，
  第 16 天作为截断日不进 UI**。
- **备用 App 图标在侧载产物上不可用**（`CFBundleAlternateIcons` 依赖签名侧支持），
  设置入口会如实显示「不可用」，不给点了没反应的开关。
- **MET Norway 的数值暂不上屏**：当前只作为逐字段降级链的一环，状态可在设置页查看。
- **无后台刷新**：数据在 App 前台刷新（冷启动 / 回前台节流 / 手动下拉 / 小组件深链强刷），
  熄屏后不会被唤醒。
- 月相为近似算法（±1.85 天量级），月出月落为本地近似（±10min），非天文精确值。
- 中国等非原生覆盖区的分钟级降水是**逐小时插值**，不是实况外推。
- 历史天气依赖 ERA5 再分析资料，**有约 5 天滞后**，非实况观测。
- 尚未接入官方预警、台风轨迹。做过调研但都还没接，`docs/handover/` 下留有结论。

---

## 开发者

Windows 上也能改这个项目，但它只能在 macOS 上编译。

```bash
brew install xcodegen
make gen            # 生成 ZhishengWeather.xcodeproj（project.yml 是唯一真源）
make test           # 模拟器跑单测（783 个测试方法 / 78 个文件）
make ipa            # 出未签名 IPA
```

**工程结构**

```
project.yml                  XcodeGen 工程定义（*.xcodeproj 不入库）
Core/                        ★ 主 App 与小组件共用编译：模型 / 逻辑 / 存储 / 网络
ZhishengWeather/             主 App：入口 / 主屏 / 设置 / 定位
ZhishengWeatherWidget/       小组件：6 families，自力取数
ZhishengWeatherTests/        XCTest，不连真实网络
qa-static-check.sh           静态门禁（48 项性质检查）
docs/                        类图 / 时序图 / 交接设计文档
```

> `Core/` 被两个 target 同时编译，所以它里面禁 `import UIKit`、禁 `try!` / `fatalError`，
> 也**禁任何凭据读取**——否则密钥会被同时编进 Widget 二进制。这些由静态门禁守着。

**CI**：`.github/workflows/ios.yml` 跑在 `macos-14`，流程是 生成工程 → 单测 → 归档 →
打包 → 上传 IPA；失败时把错误抽成 annotation，不下载日志也能看原因。

**静态门禁**（不是 CI 的一部分，需手动跑）：

```bash
bash qa-static-check.sh       # 约 2 分钟；当前基线 PASS 47 / FAIL 0 / WARN 1
```

它不编译、不跑测试——**PASS 不代表单测通过**，后者只以 CI 的测试作业为准。

---

## 许可与致谢

- 本项目使用 **MIT License**，见 [LICENSE](LICENSE)。
- 天气数据主要由 [Open-Meteo](https://open-meteo.com) 提供，
  另有 [MET Norway](https://api.met.no) 作交叉校验；日出日落由
  [sunrise-sunset.org](https://sunrise-sunset.org) 提供。三家均免注册，特此感谢。
- 设计原型来自 Android 版[枳生天气](https://github.com/zhishengplus/ZhishengWeather)（MIT），
  本项目是它的 Swift / SwiftUI 重写版。

---

## 已知问题：桌面小组件在重签侧载渠道上无法工作

**⏳ 这一节需要熟悉 WidgetKit 与 iOS 分发机制的开发者协助，我们暂时解决不了。**

### 现象

小组件**能添加到桌面**（说明打包、签名、扩展注册都成功），但**永远显示占位块，
取不到任何数据**。在编辑界面手动选过具体城市也无效。同一台设备上主 App 取数完全正常，
网络没有问题。

### 已排除的可能

| 排查项 | 结论 |
|---|---|
| `.appex` 未打包进 IPA | 已用字节级校验确认存在，可执行文件是真实 Mach-O |
| 扩展声明错误 | `NSExtensionPointIdentifier` 正确，部署目标 17.0 |
| 网络不通 | 主 App 同一网络下取数正常 |
| 取数代码有 bug | 单测覆盖该路径且全绿；失败分支会显式返回状态而非静默 |
| 缺 `init()` 导致配置读回被重置 | 已补，症状吻合，但**未解决真机问题** |
| 城市 id 编解码不一致 | 两侧同走 `City.makeID`，逐字相同 |

### 仍然不明的地方

`TimelineProvider` 的 `timeline(for:in:)` 在真机上似乎**从未被调用**——
桌面停留的是 WidgetKit 用来占位的 `redacted` 渲染。已加 `.unredacted()` 让失败可见，
但仍无法确定系统为什么不下发时间线请求。可能与以下之一有关：

- 重签后 AppIntents 元数据在两个 bundle 间的可见性；
- 侧载渠道下 WidgetKit 的时间线调度策略；
- 或某个我们尚未发现的配置问题。

### 我们需要的帮助

如果你熟悉以下任一方向，**欢迎提 Issue 或 PR**：

1. 侧载（Feather / 企业证书 / TrollStore）渠道下 WidgetKit 的已知限制；
2. `WidgetConfigurationIntent` + `AppEntity` 在重签环境下的可靠做法
   （业界有项目改用 `@Parameter var city: String?` + `optionsProvider` + 自编码 ID，
   完全绕开实体反序列化，本项目正考虑照此重做）；
3. 如何判断"系统到底有没有调用过 `getTimeline`"。

详细的排查过程、每一步的证据、以及已排除项，都记在
`docs/handover/` 与 `docs/DEV-NOTES.md` 里，不用来问我。

**在解决之前，我们把精力放在把天气本身做完整上。**
