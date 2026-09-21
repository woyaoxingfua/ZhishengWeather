# 枳生天气 · iOS（ZhishengWeather）

磷光终端风、无广告无账号的天气 App；主 App + WidgetKit 桌面小组件。

- 语言 / UI：Swift 5.9+ / SwiftUI
- 最低版本：iOS 17.0
- 第三方依赖：**0 个**
- 工程生成：**XcodeGen**（本仓库只维护 `project.yml`，`*.xcodeproj` 不入库）
- 数据源：**多源可插拔**（见第 2 节）——主源 Open-Meteo + 两个免注册辅助源

**额度纪律（quota discipline）**：给单一源加字段**不增加请求次数**（同一条 URL 内合并参数）；
ensemble 走独立域名独立慢节奏（3 小时节流）；气候档案用户进入页面才请求 + 本地 5 分钟缓存。

## 逐日预报的承诺边界（AC-A10，钉死）

> **接口取 16 天，UI 只承诺 15 天。第 16 天是"截断日"。**

Open-Meteo 在 `forecast_days=16` 时，最后一天（第 16 天）**只填充到下午**，
其余为 `null`（服务端明文允许的行为，不是接口异常）。因此：

- `daily` 请求面带 16 天，但**UI 的逐日档位末端是 15**，第 16 天**不进 UI**；
- 解码侧对**数组末尾的 `null` 元素**做容忍（见 `OpenMeteoResponse.Daily` 的
  `[Double?]?` 纪律）——历史教训：曾把它写成非可选，导致**整包解码失败、
  主屏与小组件同时无数据**；
- 这条承诺**同时写在本文档与 `README` 里**，改动需同步。

---

## 1. 功能总览（与代码逐一对应，无虚标）

### 天气数据
- **实况 18 项**：气温 / 体感 / 湿度 / 天气码 / 风速 / 风向 / 昼夜 / 气压 /
  能见度 / 露点 / 云量 / 阵风 / **降水量 / 雨 / 阵雨 / 降雪 / UV 指数**。
- **逐时 8 项序列**：气温 / 天气码 / 降水概率 / **降水量** / **风速 / 阵风 /
  体感温度 / 风向**（24 小时，按选中城市时区渲染）。
- **逐日 17 项**：高低温 / 天气码 / 降水概率 / **降水合计 / 雨合计 / 降雪合计 /
  最大风速 / 最大阵风 / 主导风向 / 昼长 / 日照时数 / 体感高低温**。
- **短期 / 中期 / 长期三档**（3 / 7 / 15 天）+ 15 天独立页。
- **日出日落** + **昼长** + **距日落倒计时** + **昨日对比**（昨日整对象：温度与现象同显）。
- **月相**（八相分桶近似）+ **月出月落**（本地近似 ±10min）。
- **生活指数**（本地估算，标注「本地估算·仅供参考」）。

### 新增可视化（P2）
- **逐时降水图**：一张图同时承载**降水量（mm，柱）**与**降水概率（%，折线）**，
  两者**各有明示的尺**，不叠成一根含混的柱（mm 与 % 是两种量纲，叠在一起就是骗人）。
  全窗口无降水 → 显示**完整晴窗**并标注「未来 24 小时无明显降水」；数据不足 → 整块隐藏。
- **逐时风力图**：**实心柱 = 平均风速、空心柱 = 阵风**，两序列**共用同一把标尺**
  （同为 m/s，只有同尺才谈得上比较）；下方一行**逐时风向箭头**。
  ⚠️ 箭头画的是**风的去向**（气象风向是「风**来向**」，故旋转 `+180°`），
  卡内图例逐字写明这一约定——不写就会读反 180°。
- **空气质量 24 小时趋势**：六档语义色分段，**`nil` 处曲线断开**
  （绝不连线跨越缺口，否则"没数据"会被画成"空气变好了"）。
- **短时降水卡**：未来 2 小时 15 分钟粒度降水柱 + **逐柱概率**；
  标注「**由逐小时插值，非实况外推**」（诚实标注纪律：禁止"分钟级 / nowcast"措辞）；干窗整卡隐藏。
- **逐日行展开**：日降水合计 / 风（最大风 · 阵风 · 主导风向）/ **昼长与日照（分列标签）** /
  体感高低温。
- **历史页**：逐日降水合计。
- **决策优先**：一句话天气摘要（含「当前时段可能下雨，出门带伞」式文案）、
  集合预报概率语言（30 成员不确定性叙述）、雨伞提醒（本地通知，干→湿才触发）。

### 单位与格式化纪律
- **同类量只有一个格式化入口**（`Core/Logic/WeatherFieldFormatters.swift`）：
  `WindDirectionFormatter` / `DurationFormatter` / `PrecipitationFormatter`(mm) /
  `SnowfallFormatter`(**cm**)。
- ⚠️ **降雪恒以 cm 展示，绝不走 mm 换算**（差 10 倍）。降雪与降水**物理分离成两个入口**，
  并有单测钉住"同一数值经两个入口产出不同字符串"。理由：本仓库**已经因为
  `windDirectionText` 在两处各写一份而漂移过**，降雪绝不重演。
- **日照时数 ≠ 昼长**：是两个量，**分别标注、绝不共用标签**。
- **`0` 与"缺失"严格区分**：`0 mm` / `0%` / `0°` 都是合法值，如实显示；
  只有服务端返回 `null`（或整键缺失）才是"未知"，显示 `--` 或整段隐藏。

### 主题 / 小组件 / 集成
- **主题三档**：深色 / 浅色 / 跟随系统（默认跟随系统）。小组件只跟随系统深浅。
- **App 图标**：默认图标 + **Jade / Rain 两套备用图标**（备用图标在侧载产物上不可用，
  入口会**如实标注「不可用」**而不是给一个点了没反应的开关）。
- **Widget 6 families**：Small / Medium / Large + accessoryCircular / accessoryRectangular /
  accessoryInline。
- **设置页**：单位偏好、外观三档、雨伞提醒开关、**多源管理**（见第 2 节）、数据状态面板。
- **静态快捷方式 + AppIntents**：主屏长按 + 快捷指令 App / Spotlight / 操作按钮。

---

## 2. 多数据源（可插拔）

### 当前接入的源

| 源 | rawValue | 角色 | 提供 | 凭据 |
|---|---|---|---|---|
| Open-Meteo forecast | `open-meteo-forecast` | **主源** | 实况 / 逐时 / 逐日 / 短时降水 | 免 Key |
| Open-Meteo air-quality | `open-meteo-air-quality` | 辅助（独立链路） | 空气质量 | 免 Key |
| sunrise-sunset.org | `sunrise-sunset` | 辅助 | 日出 / 日落 / 太阳正午 / 昼长 | 免 Key |
| **MET Norway** | `met-norway-forecast` | 辅助 | **基础数值六项**（温 / 压 / 湿 / 云量 / 风速 / 风向） | 免 Key（需带可识别 UA） |

> MET Norway 是**与 Open-Meteo 不同的数值模式**——模式独立才有交叉校验价值。
> 它**只提供它真实拥有的六个字段**：`compact` 端点**没有阵风**、**没有降水概率**，
> 因此**不声明**这些能力（声明了拿不到会让该源被 `EV-1` **误摘**）。

### 骨架结构（新增一个源现在很便宜）

```
SourceID（enum, CaseIterable）        源标识
SourceCapability                     我能干什么（10 项能力）
WeatherFieldKey                      逐字段寻址（可降级的字段）
FieldPatch / FieldValue              稀疏字段补丁（[WeatherFieldKey: FieldValue]）
FieldSupplying / DataFieldSource     取数协议（声明面 + 能力面）
SourceDescriptor / SourceDirectory   源的描述符 + 唯一手工登记点
FieldSourceRegistry                  按能力返回有序源链
FieldFallbackResolver                逐字段合并（纯函数）
SourceHealthTracker / Ledger         健康状态 / 持久化账本
SourceExclusion / ExclusionPolicy    摘除判据 EV-1 / EV-3 + 阈值集中
```

**接入一个新源的代价**：四件套（Endpoint / Response / Mapper / Service）+
**描述符一项** + 组装一行。骨架泛化前的代价是"新增 5 文件 + 改 9 个既有文件，
其中 5 处漏改会静默哑火"（例如漏登记描述符 → 自动摘除哑火且设置页不显示该源）。
现在**漏登记会被测试抓住**（描述符双射守卫），不再静默。

### 合并与降级的两条硬性质（被单测穷举）

1. **主源某字段非 nil 时，绝不被备源覆盖**（provenance 标 `.primary`）；
2. **绝不平均 / 绝不融合** —— 循环体每个字段**只"选择"一个来源**，
   **结构上不存在平均路径**，不是靠"记得别写平均"来保证。

两条性质对 `WeatherFieldKey.allCases` **全枚举逐字段断言**——将来加字段**自动被覆盖**。

### 自动摘除（只对辅助源生效）

- **EV-1**：必填字段**连续 3 次缺失** → 本会话摘除；
- **EV-3**：`401/403` → 本会话摘除；`429` → **冷却 600 秒**（冷却期内**确实不发请求**）；
- 优先级：`用户手动停用 > 会话摘除 > 冷却`；
- **主源不参与自动摘除**（它失败仍走既有的缓存降级路径）；
- 账本读坏 JSON → **空账本且不覆盖写**；被覆盖前会把不可解析的字节**留档**到
  `storeKey + ".corrupt"`（防"一次坏 JSON 静默销毁全部历史"）。

### 来源标注

- **L1（页脚）**：数据来自哪个源，**缓存命中时也说真话**（读 App 本地记录的最近成功源）；
- **L2（字段级）**：某字段由备源补齐时，行尾标注「来自 <源名>」；
  判定标准是"**主源本应提供却缺失**的字段由备源顶上"——
  主源**从不提供**的字段（如太阳正午 / 昼长）由指定提供方给出，**不算降级**
  （早前实现把两者混为一谈，导致页脚**恒定**谎称"主源不可用"）；
- **多源管理区**：逐源显示 在用 / 备用 / 已摘除·原因 / 未配置 + 最近成功时间 + 今日用量，
  并对**参与自动摘除的源**提供手动停用开关（不参与的源**不给**开关，
  避免"点了没反应"的假开关）。

---

## 3. 目录结构

```
ZhishengWeatherIOS/
├── project.yml                  # XcodeGen 工程定义（唯一真源）
├── Makefile                     # gen / build / ipa / test / clean / help
├── qa-static-check.sh           # 静态门禁（45 项，见第 7 节）
├── .github/workflows/ios.yml    # CI：生成工程 → 测试 → 出未签名 IPA
├── Assets.xcassets/             # AppIcon + 两套备用图标
├── Config/                      # Info.plist / entitlements
├── Core/                        # ★ 主 App 与 Widget 共用编译（禁止 UIKit）
│   ├── Models/  Logic/  Storage/  Networking/  UI/
├── ZhishengWeather/             # 主 App target（入口 / 主屏 / 视图模型 / 定位 / 设置）
├── ZhishengWeatherWidget/       # 小组件 target（6 families，自力取数）
├── ZhishengWeatherTests/        # XCTest（783 个测试方法 / 78 个文件）
└── docs/                        # 类图 / 时序图（mermaid）+ handover 交接文档
```

> ⚠️ `Core/` 会被 **主 App 与 Widget 两个 target 同时编译**，故其中：
> 禁 `import UIKit`、禁 `UIApplication`、禁 `try!` / `fatalError`，
> 且**禁出现任何 Keychain API 或凭据类型**（否则密钥会被同时编进 Widget 二进制——
> 静态守卫 **SC-42a** 会抓这条）。

## 4. 生成工程并构建（macOS）

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

`Makefile` 提供了 `gen` / `build` / `ipa` / `test` / `clean` / `help` 目标。

## 5. 出未签名 IPA（自用分发）

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

## 6. CI

`.github/workflows/ios.yml` 跑在 `macos-14`，支持 `workflow_dispatch` 手动触发与
`push`（main / ios）。流程：生成工程 → **跑单测** → 归档（未签名）→ 打包 → 上传 IPA。
产物名 `ZhishengWeather-unsigned-ipa`。

失败时会把编译错误与失败断言抽成 **annotation**（无需下载日志即可看原因）。
⚠️ 该抽取步骤曾用 `| head -40` 截断，在 `set -o pipefail` 下 `head` 提前关管道会让上游
`grep`/`sed` 收 SIGPIPE，**导致"报告失败的步骤自己失败"**；已改为 `awk 'NR<=40'`
（读完输入、只打印前 40 行，不产生 SIGPIPE）。日志短时侥幸能过、一长就崩——
这类缺陷最难查。

## 7. 静态门禁（`qa-static-check.sh`）

```bash
bash qa-static-check.sh        # 48 项；耗时约 2 分钟（多轮全仓 grep），请给足超时
```

当前基线：**PASS 47 / FAIL 0 / WARN 1**（该 WARN 是 `SC-42c` 的预期提示：
App 侧尚无凭据存储实现）。

它守的是**性质**而不是文件名（改名 / 拆分 / 搬迁后守卫仍应命中），例如：
`Core/` 内不得出现 `import UIKit`、全仓禁 `try!`/`fatalError`、
widget 目录不得出现裸网络符号与骨架/凭据符号、`Core/` 不得出现凭据读取符号、
widget kind 字符串逐字不变（防存量组件失效）、
以及**逐日档位末端恒为 15 且 README 写明 16 天截断日**（`SC-43`，即本文档开头那条承诺的守卫）。

> ⚠️ **已知缺口**：本脚本**尚未接进 CI**，目前只有人手动跑才存在。
> 且它**不编译、不执行测试**——`PASS` **不代表单测通过**，
> 测试是否通过**只以 CI 的测试作业为准**。
>
> 另：写这类守卫时**注释过滤的锚点要认准**——对**单文件** `grep -n`（输出「行号:内容」）
> 必须用 `^[0-9]+:`；用成 `:[0-9]+:`（那是给**目录** `grep -rn` 的「文件:行号:内容」用的）
> 会**永不匹配、过滤形同虚设**，把注释里的内容当成代码误报。

## 8. 真机安装（自签 sideload）

1. 从 Actions 下载 `ZhishengWeather-unsigned-ipa`（或自行按第 5 节构建）。
2. 用 **Sideloadly / AltStore / TrollStore** 等工具以个人 Apple ID 重签名后安装。
3. **打开主 App 至少一次**（触发首次取数）。
4. ⚠️ **小组件必须手动选城市**：长按桌面小组件 → **编辑小组件** → 城市 → 选一个具体城市。
   原因见下。

### 为什么小组件必须手动选城市

未签名 / 重签侧载的产物上 **entitlements 不生效 → App Group 共享容器不可用**。
小组件因此改为**自力取数**（自己联网，不依赖主 App 写数据），但**城市列表**仍读共享容器：
容器不可用时城市列表为空 → 默认的「跟随 App」哨兵**解析不出城市** →
**小组件根本不会发起取数**，于是长期停在空态。

空态会显示提示行（如「长按小组件 → 编辑，选择城市」）。**若你在小尺寸下看不清那行字，
这就是原因——去编辑里选个城市即可。**

## 9. App Group（当前是**可选**的）

- App Group ID：`group.com.zhisheng.weather`
- **不再是小组件工作的前置条件**：小组件自力取数，容器不可用时**优雅降级**。
- 容器可用时它会额外提供**城市列表**（供小组件编辑界面选择），仅此而已。
- 「共享容器是否可用」可在**设置页的数据状态面板**里看到。

<details>
<summary>若你的签名方式确实带上了 App Group（付费账号 + 正确配置），以下是配置清单</summary>

1. 使用**付费** Apple Developer 账号（免费账号不支持 App Groups）。
2. 在 *Identifiers → App Groups* 注册 `group.com.zhisheng.weather`。
3. 在**两个** App ID 上启用并勾选：`com.zhisheng.weather`（主 App）、
   `com.zhisheng.weather.widget`（小组件）。
4. 使用的 Provisioning Profile 必须**包含**该 App Group（否则签名后被剥离）。
5. 重签名时确认 `com.apple.security.application-groups` 未被丢弃。
6. **排查**：调用 `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`，
   返回 `nil` 即 entitlement 未生效。
</details>

## 10. 测试

- **783 个测试方法 / 78 个测试文件**；唯一门禁是 CI 的模拟器测试作业。
- 单测**不打真实网络**：全部喂本地构造的 JSON；
  「末尾 `null` 容忍」「`0` 与缺失区分」「旧缓存缺键兼容」都有专门用例。
- 开发机是 Windows（**无 Xcode**）时无法本地编译，**绝不以"静态检查全绿"当作测试通过**。

## 11. 已知限制（如实列出）

- **MET Norway 的数值目前不上屏**：它只作为**逐字段降级链的第二环**存在，
  额外价值体现在**设置页多源管理**里的一行真实状态。数值分歧对比（诊断视图）**尚未做**。
- **逐时风向只有箭头 + 峰值时刻的方位文字**：24 列时每列可用宽度仅约 13pt，
  「西南」两字在 9pt 下需约 18pt，逐列写中文必然与邻列压字。
- **能提供官方预警 / 分钟级外推 / 生活指数 / 台风的源尚未接入**（见第 12 节）。
- 月相为平均朔望月近似 + 八相均分分桶（每相约 ±1/16 朔望月 ≈ ±1.85 天），
  非天文精确满月时刻；分桶边界附近可能与专业天文 App 差 1 天量级。
- 月出月落为本地近似（±10min）；极地 / 无事件日显示「今日无月出」式文案。
- 中国等非原生覆盖区的 15 分钟短时降水为**逐小时插值**（非实况外推）。
- 历史天气 / 气候档案依赖 ERA5 再分析资料（**有 ~5 天滞后，非实况观测**）。
- **备用 App 图标在侧载产物上不可用**（`CFBundleAlternateIcons` 依赖签名侧支持），
  入口会如实标注「不可用」。
- 无后台任务调度：数据刷新发生在 App 前台（冷启动 / 回前台节流 / 手动刷新 / Widget 深链强刷）。
- **无凭据存储实现**：本轮所有源都免 Key。接入需 Key 的商业源时，
  凭据须落在 **App 专有文件 + Keychain**，**绝不可放 `Core/`**
  （`Core/` 被双 target 编译，密钥会同时进 Widget 二进制）。
  另需注意：**重签换了签名身份（TeamID 变化）后，Keychain 里的凭据会读不到**，
  届时需要重新录入。

## 12. 已调研、尚未接入的源

以下均**未接入**，仅记录调研结论（依据为官方文档原文 + 实测，2026-09-20）：

- **和风天气 QWeather**：唯一在免费额度内**同时**提供「官方分级预警 + 中国 1km 分钟级降水」
  的服务商（50,000 次/月，个人开发者邮箱注册，可商用**须署名**）。
  注意三个**时间炸弹**：① 2027-02-01 起 API KEY 限 1000 次/天（JWT 无限制）；
  ② `devapi.qweather.com` 2026-01-01 停服、`api.qweather.com` 2026-06-01；
  ③ 旧 v7 接口逐个停服（预警 v7 **2026-10-01**）。→ 必须用**新 v1 + JWT + 独立 API Host**。
- **中国天气网 `findAlarm`**：免 Key、实测可用、带省市县红橙黄蓝计数；
  但它是**站点内部接口、无文档无授权无 SLA**，且**没有级别枚举字段、没有坐标**
  （级别需从标题文字解析、城市归属只能按省份过滤）→ 只可作兜底 / 对比，不可当主源。
- **Apple WeatherKit**：50 万次/月、Swift 原生、免管 Key，但需 99 美元开发者会员，
  且预警与分钟级均为 "select regions"（**中国是否覆盖未验**）。
