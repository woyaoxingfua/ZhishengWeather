# 维护者笔记（DEV NOTES）

> 这份文档是**给维护这个项目的人**看的，刻意不放进 README。
> README 是给外人（想用这个 App 的人 / 路过看你代码的开发者）看的，
> 而下面这些内容是**内部决策的来龙去脉**——外人不需要知道，但维护者不该丢。
>
> 迁移自 2026-09-21 的 README 重写：旧 README 把两类读者混在一起，
> 导致它既是门面又是 runbook，两件事都没做好。

---

## 1. 逐日预报：为什么是 15 天而不是 16 天

**当前约定**：接口请求面带 16 天，UI 逐日档位末端是 15，第 16 天是**截断日**、不进 UI。

- 原因：Open-Meteo 在 `forecast_days=16` 时，第 16 天**只填充到下午**，其余为 `null`。
  这是服务端明文允许的行为，不是接口异常。
- 解码侧对应纪律：`OpenMeteoResponse.Daily` 的字段必须是**可选数组**（`[Double?]?`），
  容忍数组末尾的 `null` 元素。

**历史教训（别回头再踩）**：曾把末尾 `null` 写成非可选 → **整包解码失败 →
主屏与小组件同时无数据**。症状看起来像"网络挂了"，实际是 `DecodingError`。

这条承诺由静态守卫 **SC-43** 钉住：

| 守卫 | 锚的性质 |
|---|---|
| SC-43a | `DailyForecastSection.swift` 的**代码**（去注释）不得出现裸 `16` |
| SC-43b | `15` 档位必须存在（防止"把 15 也删掉"让 43a 假通过） |
| SC-43c | README 必须同时出现「15 天」「16 天」「截断日」（锚实质，不锚措辞） |

> 注意：改动.UI 档位时，**代码与 README 要同步改**，否则 SC-43c 会红。

---

## 2. 单位与格式化纪律

**同类量只有一个格式化入口**：`Core/Logic/WeatherFieldFormatters.swift`
（`WindDirectionFormatter` / `DurationFormatter` / `PrecipitationFormatter`(mm) /
`SnowfallFormatter`(**cm**)）。

- **降雪恒以 cm 展示，绝不走 mm 换算**——差 10 倍。降雪与降水物理分离成两个入口，
  并有单测钉住"同一数值经两个入口产出不同字符串"。
- **日照时数 ≠ 昼长**：两个不同的量，分别标注、绝不共用标签。
- **`0` 与"缺失"严格区分**：`0 mm` / `0%` / `0°` 都是合法值，如实显示；
  只有服务端返回 `null`（或整键缺失）才是"未知"，显示 `--` 或整段隐藏。

**历史教训**：本仓库已经因为 `windDirectionText` 在两处各写一份而漂移过一次，
所以"单一入口"不是洁癖，是还债。

---

## 3. 多源骨架的内部约定

### 结构清单

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
描述符一项 + 组装一行。

骨架泛化**之前**的代价是"新增 5 文件 + 改 9 个既有文件，其中 5 处漏改会静默哑火"
（例如漏登记描述符 → 自动摘除哑火、设置页不显示该源）。现在**漏登记会被测试抓住**
（描述符双射守卫），不再静默。

### 两条硬性质（被单测穷举）

1. **主源某字段非 nil 时绝不被备源覆盖**（provenance 标 `.primary`）；
2. **绝不平均 / 绝不融合**——循环体每个字段只"选择"一个来源，
   **结构上不存在平均路径**，不是靠"记得别写平均"来保证。

两条都对 `WeatherFieldKey.allCases` **全枚举逐字段断言**，将来加字段自动被覆盖。

### 自动摘除（只对辅助源生效）

- **EV-1**：必填字段连续 3 次缺失 → 本会话摘除
- **EV-3**：`401/403` → 本会话摘除；`429` → 冷却 600 秒（冷却期内**确实不发请求**）
- 优先级：`用户手动停用 > 会话摘除 > 冷却`
- **主源不参与自动摘除**（它失败仍走既有的缓存降级路径）
- 账本读坏 JSON → **空账本且不覆盖写**；被覆盖前把不可解析的字节**留档**到
  `storeKey + ".corrupt"`（防"一次坏 JSON 静默销毁全部历史"）

### 来源标注的判定标准

- **L1（页脚）**：数据来自哪个源，**缓存命中时也说真话**（读本地记录的最近成功源）
- **L2（字段级）**：某字段由备源补齐时，行尾标注「来自 <源名>」

判定标准是"**主源本应提供却缺失**的字段由备源顶上"才算降级；
主源**从不提供**的字段（如太阳正午 / 昼长）由指定提供方给出，**不算降级**。

**历史教训**：早前实现把两者混为一谈，导致页脚**恒定**谎称"主源不可用"。

### MET Norway 的定位

它与 Open-Meteo 是**不同的数值模式**——模式独立才有交叉校验价值。
`compact` 端点**没有阵风、没有降水概率**，因此**不声明**这些能力
（声明了却拿不到会让该源被 `EV-1` **误摘**）。

### 凭据（接入需 Key 的商业源时）

凭据须落在 **App 专有文件 + Keychain**，**绝不可放 `Core/`**
（`Core/` 被双 target 编译，密钥会同时进 Widget 二进制）。
另需注意：**重签换了签名身份（TeamID 变化）后，Keychain 里的凭据会读不到**，
届时需要重新录入。

---

## 4. App Group：为什么降级成"可选"

App Group ID：`group.com.zhisheng.weather`

分发渠道是**侧载自用**（未签名 IPA → 第三方重签），**entitlements 不生效 →
共享容器不可用**。所以小组件改为**自力取数**（它的问题在于：它读不到容器里的城市列表，
默认的「跟随 App」哨兵解析不出城市 → **根本不发起取数** → 长期空态）。

容器可用时它额外提供**城市列表**（供小组件编辑界面选择），仅此而已。
「共享容器是否可用」可在**设置页的数据状态面板**里看到。

若未来签名方式确实带上了 App Group（付费账号 + 正确配置），配置清单是：

1. 使用**付费** Apple Developer 账号（免费账号不支持 App Groups）
2. 在 *Identifiers → App Groups* 注册 `group.com.zhisheng.weather`
3. 在**两个** App ID 上启用并勾选：`com.zhisheng.weather`（主 App）、
   `com.zhisheng.weather.widget`（小组件）
4. Provisioning Profile 必须**包含**该 App Group（否则签名后被剥离）
5. 重签名时确认 `com.apple.security.application-groups` 未被丢弃
6. **排查**：`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`
   返回 `nil` 即 entitlement 未生效

---

## 5. CI 与静态门禁

### CI（`.github/workflows/ios.yml`，`macos-14`）

流程：生成工程 → 跑单测 → 归档（未签名）→ 打包 → 上传 IPA（产物名
`ZhishengWeather-unsigned-ipa`）。失败时把编译错误与失败断言抽成 annotation。

⚠️ **已修的坑**： annotation 抽取曾用 `| head -40` 截断，在 `set -o pipefail` 下
`head` 提前关管道会让上游 `grep`/`sed` 收到 SIGPIPE，**导致"报告失败的步骤自己失败"**。
已改为 `awk 'NR<=40'`（读完输入、只打印前 40 行，不产生 SIGPIPE）。
日志短时侥幸能过、一长就崩——这类缺陷最难查。详见 `docs/CI-pitfalls.md`。

### 静态门禁（`qa-static-check.sh`）

```bash
bash qa-static-check.sh        # 48 项；耗时约 2 分钟（多轮全仓 grep），请给足超时
```

当前基线：**PASS 47 / FAIL 0 / WARN 1**（WARN = `SC-42c`：App 侧尚无凭据存储实现）。

**设计原则：守性质，不守文件名**——改名 / 拆分 / 搬迁后守卫仍应命中。例如：
`Core/` 内不得出现 `import UIKit`、全仓（swift）禁 `try!`/`fatalError`、
widget 目录不得出现裸网络符号与骨架/凭据符号、`Core/` 不得出现凭据读取符号、
widget kind 字符串逐字不变（防存量组件失效）。

> ⚠️ **已知缺口**：本脚本**尚未接进 CI**，目前只有人手动跑才存在。
> 且它**不编译、不执行测试**——`PASS` **不代表单测通过**，
> 测试是否通过**只以 CI 的测试作业为准**。

**写守卫时踩过的坑（值得记）**：注释过滤的**锚点要认准**——
对**单文件** `grep -n`（输出「行号:内容」）**必须**用 `^[0-9]+:`；
用成 `:[0-9]+:`（那是给**目录** `grep -rn` 的「文件:行号:内容」用的）会**永不匹配、
过滤形同虚设**，把注释里的字符串当成代码误报（SC-43a 首版就栽在这里）。

---

## 6. 测试纪律

- **783 个测试方法 / 78 个测试文件**；唯一门禁是 CI 的模拟器测试作业。
- 单测**不打真实网络**：全部喂本地构造的 JSON。
  「末尾 `null` 容忍」「`0` 与缺失区分」「旧缓存缺键兼容」都有专门用例。
- 开发机是 Windows（**无 Xcode**）时无法本地编译，
  **绝不以"静态检查全绿"当作测试通过**。

---

## 7. 已调研、尚未接入的源

以下均**未接入**，仅记录调研结论（依据为官方文档原文 + 实测，2026-09-20）：

- **和风天气 QWeather**：唯一在免费额度内**同时**提供「官方分级预警 + 中国 1km 分钟级降水
  + 生活指数」的服务商。
  > ⚠️ **本条已于 2026-10-03 更正**（原记载有错，见下）。更早的调研
  > `PRD-zhisheng-ios-API-expansion.md` §11-5 记录的是**对的**，是我转述时抄错了。

  **正确的额度**（依据官方 2025-03-01 公告 + 定价页「Weather and Essential Services」组）：
  - 免费额度 = **50,000 次/月**。网上流传的「1000 次/天」**已于 2025-04-01 取消**
    （原免费订阅的每日额度并入用量计费），**不要再按"每天 1000 次"理解**；
  - 免费组**含**：Weather、Minutely Forecast、**Warning**、Weather Indices、
    Air Quality、Time Machine、GeoAPI；
  - **不含**：**Tropical Cyclone（台风）**属「Storm and Ocean」组（¥0.003 起/次，
    **第一次调用即计费**）、Solar Radiation（¥0.3/次）。→ 台风别指望免费额度；
  - 分钟级降水与台风**仅覆盖中国**；
  - 超额按阶梯计费**不停服**（¥0.0007/次起）；注册需邮箱+手机号+实名，**不需信用卡**。

  **接入的三个真实障碍**（按坑的大小排序）：
  ① **必须在设备端持有 Ed25519 私钥**生成 JWT（EdDSA 签名，exp ≤ 24h）。
     私钥进客户端 = 可被提取 → 这是**架构级改动**（凭据须落 App 专有 Keychain，
     绝不可放 `Core/`，见 §3 凭据纪律），不是加个 Header 而已；
  ② **公共域名已全部停服**：`devapi.qweather.com` 2026-01-01 停、
     `api.qweather.com` / `geoapi.qweather.com` 2026-06-01 停。
     必须改用**每账号唯一的 API Host**（`{random}.{sub}.qweatherapi.com`，控制台取），
     且 **API Host 本身就是身份认证的一部分** → host 需按账号配置化，不能内置；
  ③ **又一次分批停服在进行中**：`/v7/warning/now` 停服 **2026-10-01**（已发生）、
     `/v7/grid-weather/*` 与 `/v7/weather/*` 停服 **2027-06-01**
     （官方博客写 2027-08-01，**两处自相矛盾，以控制台为准**）。
     → 接则必须用**新 v1 + JWT + 独立 API Host**。

  **模式**：走 **BYO-Key**（用户自带 host + key，只存本机 Keychain，默认 OFF），
  不内置任何密钥——设计见 `PRD-zhisheng-ios-API-expansion.md` 的 D27 与 AC-B2-*。
- **RainViewer**：雷达回波，**无限次调用、免注册、免 Key**（本项目实测 2026-10-03：
  `weather-maps.json` 200、`radar.past` 实有 13 帧）。
  三个坑：① **仅个人/教育用途**，商用需另谈；② **强制署名** "Weather data by RainViewer"；
  ③ **`radar.nowcast` 实测为空数组**（独立 `nowcast.json` 返 404）→ **临近预报拿不到**，
  官方文档与实际不符，**别按文档设计**；另瓦片 **zoom 上限实测为 5**（z6+ 返占位图）。
- **WeatherAPI.com**：10 万次/月免费（官方 pricing 表 Free 行），免费层含
  Weather Alerts + Weather Maps + AQI + Astronomy + Geocoding。
  坑：免费层 uptime 仅 **95.5%**、无 SLA；预警是否覆盖中国大陆**未从官方原文证实**。
- **明确不推荐**（2026-10-03 核实，避免重复调研）：
  - **彩云天气**：免费版 0 元 / 1 万次 / **QPS 1**（多城市 + 小组件刷新是硬伤），
    且**免费版不含气象预警**（在 25 元/万次档才有）。第三方站的「400/天」「1000/天」
    与官网矛盾，勿信。
  - **OpenWeatherMap**：One Call 4.0 仅首 1000 次/日免费；天气地图/降水图要 £450/月。
  - **Apple WeatherKit**：50 万次/月免费，但**必须付费 Apple Developer Program（$99/年）**，
    且预警**禁止改写文案**、须内嵌 Apple 详情页链接并显示 Apple Weather 商标。
  - **Tomorrow.io**：免费仅 500 次/日；空气质量/花粉/雷电**全在付费**；瓦片也计次。
  - **nmc.cn / 中国气象局**：`/rest/weather?stationid=54511` 实测返回**空数据**
    （`{"code":0,"data":""}`），无官方开放 API 文档，属未授权接口，**不用于产品**。
- **中国天气网 `findAlarm`**：免 Key、结构完整（105 站 / 16 类 / 带发布时间），
  但 **`dt=20240805144545`，数据冻结在 2024-08-05** → 典型「能解析但不可信」。
  若接入**必须做新鲜度断言**（`dt` 差 > 6h 判 stale 且不展示）。
- **Apple WeatherKit**：50 万次/月、Swift 原生、免管 Key，但需 99 美元开发者会员，
  且预警与分钟级均为 "select regions"（**中国是否覆盖未验**）。

---

## 9. 小组件的空态链路（2026-09-23 真机反馈后查明）

### 真机事实

用户用 **Feather + 购买的证书**重签安装。现象：**小组件能被添加到桌面，但一直显示「暂无数据」**。

CI 产物字节级取证（run `35751372045`，head_sha `ce021f8`）确认打包无问题：
`Payload/ZhishengWeather.app/PlugIns/ZhishengWeatherWidget.appex` 存在，可执行文件
758,312 字节（真实 Mach-O），`NSExtensionPointIdentifier = com.apple.widgetkit-extension`。
**「能添加」本身就是证据**——extension 的打包、重签、系统注册三步都已通过，
问题只可能在数据链路，不在安装侧。

定性：当前处在 `.noCity` 空态。购买证书**并不**带来 App Group——容器要靠 profile 里
登记 `com.apple.security.application-groups` 才存在，共享/购买的企业 profile 里
不会有我们自己的 `group.com.zhisheng.weather`（那是本仓库持有的 App Group）。

### 「选了具体城市」这条路是通的（已核验到符号级）

- 持久化：`WidgetCitySelectionIntent.city`（`Core/Logic/WidgetCityIntent.swift` 内
  那个**非可选、无 `default:`** 的 `@Parameter`）由系统按实例存取，
  **零共享容器写入** → 不存在"选了也白选"。
- 解析：`WidgetCityResolver.resolveOutcome` 的 `.fixed(let cityID:)` 分支在
  `builtIn`（`WidgetBuiltInCities` 34 城）命中，**不读 `containerAvailable`**，
  容器不可用完全不影响。
- 取数：一路到 `OpenMeteoEndpoint.url`，除 `store.loadResult()`（已容忍失败）外
  **无任何 AppGroupStore 引用**。预算 `fetchBudget = 10` / `requestTimeout = 8`，非零。

> ⚠️ **读回环节曾有第三个缺陷（2026-09 已定位并修）**：上面这条链的前提是
> `configuration.city` **真的读回了用户所选的 id**。而`WidgetCitySelectionIntent`
> 当时**没有 initializer**（`city` 又是无`default:` 的非可选 `@Parameter`）→
> Apple 要求默认值由 init 提供；缺 init 时系统回退 `WidgetCityQuery.defaultResult()`
> （= `followApp` 哨兵）→ **用户选了什么都被静默替换成默认值**，于是
> `followAppOutcome`（侧载容器 `selectedID` 恒 nil）→ `.needsConfiguration`
> → 「无城市就不取数」→ **零网络请求**。已在
> `Core/Logic/WidgetCityIntent.swift` 补`init(city:backgroundStyle:)` 修复。
> ⚠️ **仍未真机验证**，且**默认状态不能用来判断成败**（默认哨兵走`followApp`
> 分支，侧载产物上必然 `.needsConfiguration`）—— 必须**选一个具体城市**再看
> 标题那一行：真实温度 = 修好；「杭州」+`--°`「未能获取天气」= 取数链路问题；
> 仍显示 `—` = 读回仍坏。
>
> ⚠️ 另有一处**归因更正**：曾把根因记作「配置 Intent 只编入 widget target、
> 主 App 缺定义」。**该说法已证伪** —— 真正需要进主 App target 的是
> `openAppWhenRun = true` 的 `WidgetRefreshIntent`（系统在主 App 进程执行 perform()），
> 而 `WidgetCitySelectionIntent` 是 `WidgetConfigurationIntent`、只在 widget 进程
> 反序列化；且该归因解释不了「用户能选、能保存」（选择器本身工作正常）。

### 已发现的三处内部缺陷（不阻断，但应登记）

1. **回显与解析的语义不一致**（违反 P-13 同源纪律）：
   `WidgetCityQuery.entities(for:)` 末尾对无法解析的 id 兜底 `return .followApp`
   （`Core/Logic/WidgetCityIntent.swift`），而 `WidgetCityResolver.resolveOutcome`
   对同类输入给 `.needsConfiguration`。
   后果不止「显示错」：**系统反序列化 per-instance 配置时会拿 `entities(for:)`
   的返回值回写配置**，故该兜底一旦触发，等于**用哨兵静默改写用户的选择**
   （改写配置，不是界面错显）。
   已核实**当前不触发** —— 但**理由不是「id 必规范」**（`City.id` 是 `var`，且
   `City: Codable` 的合成 `init(from:)` 会从 JSON **直接解 id**、不经 `makeID`，
   故容器里一份 id 写成 `"30.250,120.170"` 的 JSON 就能产出非规范 id）。
   真正成立的理由是**侧载渠道上容器恒空**：容器不可用 → `AppGroupStore.loadCities()`
   返 `.missing`（`Core/Storage/AppGroupStore.swift`，`loadCities()` 首个 guard
   的 `else` 分支）→ `WidgetCityCatalog.rawCities` 对 `.missing/.corrupt` 给 `[]`
   → **容器数组必为空**，widget 侧根本没有解码路径；而用户选中的 id 来自
   `suggestedEntities()` 里 `WidgetBuiltInCities.cities` / `City.init` 产出的 `City`
   → 必是 `makeID` 产物，可被 `city(forID:)` 或 `city(fromCanonicalID:)` 还原。
   ⚠️ **两条分支够不着的情形**（故结论不说满）：**非规范坐标串**会被
   `city(fromCanonicalID:)` 拒绝（`WidgetCityCatalog.city(fromCanonicalID:name:)` 尾部
   那句`guard City.makeID(lat,lon) == id else { return nil }` 要求**逐字相等**）
   而落到兜底；内置目录漂移 / 城市改名同理。
   正确处置是**升级 id 映射表**，不是让兜底静默改写。
2. **`sharedContainerDown` 结构性不可达**：
   `AppGroupStore` 的 `UserDefaults` 兜底（`self.defaults = defaults ?? .standard`）
   在 `UserDefaults(suiteName:)` 返回 nil 时回落 `.standard`
   → 小组件恒读自己进程内的私有 suite，`loadResult()` 永远 `.missing`。
   后果：`WidgetPayloadStatus` 承诺的「corrupt → 如实说共享数据不可用」在侧载渠道上
   **永远不会出现**（既得利益：不会出现假警报；代价：这条状态失去意义）。
3. **编辑预览不联网导致的误判窗口**：编辑界面走 `allowNetwork == false` 的快照路径，
   选完城市后短暂显示「稍候将自动获取」/「共享数据不可用」，要等 timeline 刷新才出数。
   会自愈，但用户极易误判为「选了也没用」——这条已写进 README 提醒用户等几秒。

### 教训（写给我们自己）

这次排查里我（lead）犯过一次方向性错误，值得记下来：**按 `emptyReason` 字面 grep 后
发现"没有 View 消费"，就差点定性为" View 层忘了接文案"**——实际上 View 是通过
`entry.resolution` 传给 `WidgetCopy.conditionText/hintText` **间接**消费的，
文案和接都没问题。**按符号字面 grep 不到 ≠ 逻辑上没有这条链路。**
推演静态 bool 时必须追到实际调用点，否则会把正确的代码冤枉成 bug。

---

## 8. 其他遗留限制（偏实现的那些）

- **MET Norway 的数值目前不上屏**：只作为逐字段降级链的第二环存在，
  额外价值体现在设置页多源管理里的一行真实状态。数值分歧对比（诊断视图）**尚未做**。
- **逐时风向只有箭头 + 峰值时刻的方位文字**：24 列时每列可用宽度仅约 13pt，
  「西南」两字在 9pt 下需约 18pt，逐列写中文必然与邻列压字。
- **备用 App 图标在侧载产物上不可用**（`CFBundleAlternateIcons` 依赖签名侧支持），
  入口会如实标注「不可用」，不给点了没反应的开关。
- 无后台任务调度：数据刷新发生在 App 前台（冷启动 / 回前台节流 / 手动刷新 / Widget 深链强刷）。
