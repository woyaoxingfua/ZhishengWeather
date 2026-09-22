# 枳生天气 · iOS

> 磷光终端风的天气 App。无广告、无账号、无埋点。
> 主 App + WidgetKit 桌面小组件，零第三方依赖。

![平台](https://img.shields.io/badge/iOS-17.0%2B-3BA0F5?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.9-FF6F1E?style=flat-square)
![依赖](https://img.shields.io/badge/dependencies-0-31C9DB?style=flat-square)
![许可](https://img.shields.io/badge/license-MIT-31C9DB?style=flat-square)

本工程是 Android 开源项目 [zhishengplus/ZhishengWeather](https://github.com/zhishengplus/ZhishengWeather)
的 iOS 重写版（Swift + SwiftUI 全新实现，不是代码移植）。

---

## 它能干什么

**看天气这件事本身**：实况、逐时、逐日、月相、日出日落、空气质量、生活指数，
以及逐时降水 / 风力图、展开的逐日卡片。

**桌面小组件**：6 种尺寸（桌面 Small / Medium / Large + 锁屏 accessory 三族）。
小组件**自己联网取数**，不用开着主 App。

**多数据源**：4 个免注册数据源并行参考（见「数据来源」）。某个源不好就自动退场，
UI 会标注某个字段实际来自哪个源——不说谎。

**一句话决策**：不大篇幅铺数据，优先给「当前时段可能下雨，出门带伞」这种结论。

<details>
<summary>数据字段清单（展开看细节）</summary>

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

### ⚠️ 装完请务必多做一步：给小组件选城市

**长按桌面小组件 → 编辑小组件 → 点「城市」（当前写着「跟随 App」）→ 挑一个你所在的城市。**
列表里有 34 个内置城市（各省会和港澳台），不需要主 App 里先搜过。

**别把「暂无数据」当成坏了。** 在你选城市之前，小组件显示的就是「暂无数据」加一行小字——
这是它的一条硬纪律：**绝不偷偷替你换成别的城市**。小组件上有早于这条处理的两行字：

| 小组件上显示 | 含义 | 该做什么 |
|---|---|---|
| 暂无数据 | 还没有选定城市 | 长按 → 编辑，选城市 |
| 未能获取天气 | 联网失败 | 检查网络 |
| 定位未授权 | 选了「当前位置」但没给权限 | 先允许定位，再重新添加小组件 |

**选完不会立刻出数据，请等几秒。** 编辑界面为了不耗流量做的是离线渲染，
选完短暂显示「稍候将自动获取」，随后系统刷新才会拉到真实数据。这段时间看似没反应，其实在走数据。

**为什么非得手动选**：默认项「跟随 App」要靠 App Group 共享容器传城市，而
**重签侧载的产物上没有那份 entitlement**，容器读不到，「跟随 App」就解析不出城市。
选定具体城市后，小组件**自己联网取数**，从此不依赖容器。

> Small（小方块）上那两行字很小，看不清的话直接按上面的步骤走一遍即可。

> 想让「跟随 App」生效也有办法，但要求付费账号且 entitlements 能落到最终产物上，
> 见 `docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md`。

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
