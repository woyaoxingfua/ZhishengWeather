# ARCH · ZhishengWeather iOS 多源数据链路增量设计

> 文档类型：架构增量（architecture-delta）· 仅设计，不改 Swift 源码
> 适用仓库：`ZhishengWeatherIOS`（主 App + Widget 双 target，App Group 共享，部署目标 iOS 17）
> 冻结口径：本轮功能范围已冻结（B1 免密补全 / B2 自带和风 key / B3 UI 氛围层），本文件只描述"怎么接"，不新增范围。
> 前置输入：代码接缝审计（已完成）+ PRD（并行撰写中）。
> 编译门禁：**本机无 Xcode，唯一编译/测试门禁为 GitHub Actions macOS CI**（`xcodegen generate --spec project.yml` → `-scheme ZhishengWeather`）。

---

## 0. 三条不可谈判的红线（贯穿全文，先读）

本文件所有设计都必须满足以下三条，任一处冲突以本节为准：

| 编号 | 红线 | 依据 |
|---|---|---|
| **R1** | `project.yml` **零改动**：不新增 target、不新增依赖、不改 build setting。新 `Core/` 文件因 `Core` 已同时挂主 App（`project.yml:84`）与 Widget（`project.yml:103`）而**零配置生效**。 | `project.yml` L12-13 纪律 |
| **R2** | `supportedFamilies` **只增不减**（既有纪律，删除任何一族视为回归）。 | 既有约定 |
| **R3** | 载荷兼容：新增字段一律 **`Optional` + 合成 Codable**（旧缓存缺键 → nil，解码不炸）。**禁止**手写 `init(from:)`、**禁止** `payloadVersion`。 | `Core/Models/WeatherSnapshot.swift:54-57` |

**推论（本设计的第一原则）**：任何"新数据源"都**不是**改 `Core` 里的公共结构，而是**新增一条与既有链路物理隔离、失败隔离的独立链路**。现有代码里已经有两条这样的先例可直接复刻：空气质量链路（6 文件，全接缝）与历史 Archive 链路（5 文件，跳接缝）。

---

## 1. 新增一条数据链路的模板（6 步 + Archive 先例）

### 1.1 模板来源：空气质量链路 = "全接缝" 6 文件

审计确认：加一条数据链路 = 复刻 `AirQuality` 这套 6 文件骨架。以下为**精确插入点**（行号为当前仓库实测）：

| 步 | 角色 | 文件（相对仓库根） | 关键行 | 是否 Core |
|---|---|---|---|---|
| ① | 请求地址拼装 | `Core/Networking/AirQualityEndpoint.swift` | `enum` L21、`baseURLString` L24、`currentFields` L27、`url(latitude:longitude:)` L39 | ✅ |
| ② | 原始 DTO | `Core/Models/AirQualityResponse.swift` | `struct` L19、嵌套 `current: Current?` L43、**整键可选** | ✅ |
| ③ | 领域模型 | `Core/Models/AirQuality.swift` | `struct` L26（`Codable, Equatable, Sendable`） | ✅ |
| ④ | 纯函数映射 | `Core/Networking/AirQualityMapper.swift` | `enum` L17、`static func map(_:)` L23、负值/NaN 净化 L44-53 | ✅ |
| ⑤ | 协议 + actor | `Core/Networking/AirQualityProviding.swift` | `protocol` L18、`fetch` L20、`actor AirQualityService` L24、`decode` L57、`map` L62 | ✅ |
| ⑥ | VM 接线 | `ZhishengWeather/WeatherViewModel.swift` | 存储属性 L51、`airQuality` L54、init 默认 L66-73、refresh 触发 Task L181、fetchAndApply 触发 L320、消费者 `loadAir` L341-351 | ❌（唯一非 Core 文件） |

**步骤 ①-⑤ 是"必备五件套"**（对每一条新链路都必需）；**步骤 ⑥ 是"可选接线"**。

### 1.2 必备五件套的落位纪律

- 五个文件**全部落 `Core/`**：`Core/Networking/` 放 ①②④⑤，`Core/Models/` 放 ②③。因 `Core` 已同时挂两 target，**放进去即生效，不碰 `project.yml`**（R1 得以保持）。
- Core 纪律（沿用现有注释头）：`import Foundation` 唯一、禁 UIKit/UIApplication、禁内部 `Date()`（时钟由调用方注入）、禁 `try!`/`fatalError`。
- 错误收敛：**复用** `WeatherError`（`Core/Networking/WeatherProviding.swift:11`），不新建错误类型，保证 VM 侧 `message(for:)`（`WeatherViewModel.swift:372-386`）与 Widget 侧统一处理。
- ⑤ 的协议命名 `XxxProviding` + `actor XxxService`，**构造签名 `init(session: URLSession = .shared)`**（`AirQualityProviding.swift:30`），供测试注入。

### 1.3 步骤⑥的三档变体（决定"必需 vs 可跳"）

| 变体 | 特征 | 参考先例 | 是否写 `store`/`reloadAllTimelines` | 是否被 Widget 消费 |
|---|---|---|---|---|
| **(a) 页面切片 fire-and-forget** | 只被某个子页面消费，不进 VM | **历史 Archive**（见 1.4） | 否 | 否 |
| **(b) VM 常驻会话态** | 主屏某卡片消费，需随城市切换刷新 | **空气质量**（L51/L54/L181/L320/L341-351） | 否（仅存 VM 内存） | 否 |
| **(c) VM 常驻 + 落盘共享** | 需要 Widget 也展示 | 仅"主天气载荷"这条既有链路（B3 若要扩到 Widget 才走此档，见 §2） | 是 | 是 |

**结论（哪一步可跳过）**：
- 若新链路**不被 Widget 消费**且**只在单个页面用** → **跳过步骤⑥整步**，只写 ①-⑤ + 页面内注入（变体 a，Archive 先例）。
- 若需主屏常驻、随机切换城市 → 步骤⑥按**变体 b**（VM 加 1 个 Stub 属性 + 1 个结果属性 + init 默认 + 2 处触发 + 1 个消费者函数）。
- 只有需要进 Widget 才走**变体 c**（含 §2 的载荷设计与 §2.3 的归属校验）。

### 1.4 Archive 先例：如何"跳过步骤⑥"（fire-and-forget 标准做法）

Archive 链路**完全不经过 VM**，是"页面切片"的范式：

- 协议注入在**页面**：`ZhishengWeather/HistoricalWeatherView.swift:20`
  `var archiveService: ArchiveProviding = ArchiveService()`（默认值即生产实现，可被预览/测试覆盖）。
- 调用在**页面的 `.task`**：`HistoricalWeatherView.swift:68` `.task { await load() }` → `load()` 内 `archiveService.fetch(...)`（L182）。
- 失败处理是**页内状态机**：`enum Phase { loading / loaded / failure }`（L27-31），catch 只置 `phase = .failure`（L187-189），**不触碰任何全局 `state`**。
- **不写共享容器、不 `reloadAllTimelines()`、不动 VM**。

→ **可直接套用于 B1 的"页面级"新链路**（minutely_15 短时降水卡若只做主屏内嵌卡、往年同日 lookback 页、台风轨迹页、卫星辐射页）：只做 ①-⑤ + 在消费它的 `View` 里注入协议 + 在 `.task` 里取数。**零 VM 改动、零 App Group 改动**。

### 1.5 步骤⑥（变体 b）的精确插入点与两个坑

以 AirQuality 为模板，逐行照抄：

```swift
// WeatherViewModel.swift
private let airService: AirQualityProviding                      // ← L51 之后加一支
private(set) var airQuality: AirQuality? = nil                   // ← L54 之后加一支

init(service: WeatherProviding = WeatherService(),
     store: AppGroupStore = AppGroupStore(),
     locationProvider: LocationProvider? = nil,
     airService: AirQualityProviding = AirQualityService()) {    // ← L69 加一个默认参数
    ...
    self.airService = airService                                 // ← L73 之后赋值
}
```

- **坑 1（`@MainActor` init 默认值）**：`WeatherViewModel.swift:62-65` 有明确注释——`@MainActor` 隔离的 init 不能作为**非隔离上下文求值的 default 参数**（`LocationProvider()` 就踩过，CI 实测挂编译）。因此**新服务的 default 只有当服务是 `actor`（HTTP 服务天然是）才可内联**；若新服务是 `@MainActor` 类型，default 必须写 `nil` 并在 init 体内创建。
- **坑 2（触发时机）**：两处触发点必须**都加**——`refresh()` 内 L180-181、`fetchAndApply(for:fallbackID:)` 内 L319-320（否则切城市时不刷新新链路）。且触发**必须在主链路成功后**（`AirQuality` 放在 `store.save` 之后 L181）。

---

## 2. 多源 App Group 载荷设计

### 2.1 原则：**一个源一个 key**，`zs.weather.payload` 一个字节都不动

现有唯一载荷 key：`AppGroup.payloadKey = "zs.weather.payload"`（`Core/Storage/AppGroup.swift:16`）。其余 key 见 L14/L18/L20/L22/L25/L27。

新增源的纪律：
- **在 `AppGroup.swift` 追加常量**（该文件是"key 唯一真源"，其他文件一律引用常量，**禁止散落字符串字面量**）。
- key 命名：`zs.weather.payload.<source>`，例如
  ```swift
  static let minutelyKey   = "zs.weather.payload.minutely"
  static let radiationKey  = "zs.weather.payload.radiation"
  ```
- **新增 key 属于"数据契约"变更，不属于"工程配置"变更** → 不触发 R1。
- **禁止**把新源塞进 `SharedWeatherPayload`（`Core/Models/SharedWeatherPayload.swift:11`，只有 `snapshot`+`updatedAt`）。原因：一是会把"单快照契约"复杂化，二是 R3 兼容面扩大，三是 Widget 归属校验（§2.3）会退化。

### 2.2 `AppGroupStore` 的 save/load 重载形态

现状：`save(_ payload: SharedWeatherPayload)`（L39）+ `verifyWritten`（L46-50）+ `load()`（L58）+ `loadSnapshot()`（L69）。

**推荐做法：新增一对泛型按 key 读写**，复用既有"写后回读校验"纪律，避免为每个源写 2 个方法（N×2 爆炸）：

```swift
// Core/Storage/AppGroupStore.swift（新增，不动既有方法）
func save<Payload: Encodable>(_ value: Payload, forKey key: String) throws {
    let data = try encoder.encode(value)
    defaults.set(data, forKey: key)
    try verifyWritten(data, forKey: key)          // ← 复用 L46-50，写后回读不变量
}

func load<Payload: Decodable>(_ type: Payload.Type, forKey key: String) -> Payload? {
    guard let data = defaults.data(forKey: key) else { return nil }
    do { return try decoder.decode(type, from: data) }
    catch { print("[AppGroupStore] 解码 \(key) 失败：\(error)"); return nil }  // ← 缺键/坏 JSON → nil，绝不崩
}
```

- **保留**既有的 `save(_:)`/`load()`/`loadSnapshot()`/`updatedAt` 作为主载荷薄封装（可改为调用泛型，行为不变）。
- `verifyWritten`（L46-50）**必须**被每个新源的写路径复用——这是"共享容器不可用"（自签名/重签名最常见坑，见 `WeatherViewModel.swift:168-171`）的主动探测。

#### 2.2.1 每源独立信封（独立 `updatedAt`）

每个新源落盘用**独立信封**（镜像 `SharedWeatherPayload`），不要共用主载荷的 `updatedAt`。推荐一个泛型信封（新文件 `Core/Models/SourcedPayload.swift`）：

```swift
struct SourcedPayload<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value
    var updatedAt: Date
}
```

理由：三处节流各有各的时间戳（§2.4），必须能**按源独立判断新鲜度**；且 R3 的"旧缓存缺键 → nil"纪律在**每个 key 内独立**成立（一个源的格式演进不牵连另一个）。

### 2.3 Widget 单快照归属校验的泛化

现状（单快照硬假设）：`ZhishengWeatherWidget/WeatherProvider.swift:99-107`——读**一份** `store.load()`，仅当
`city.id == City.makeID(latitude: loaded.snapshot.location.latitude, longitude: ...longitude)`
才下发，否则 `payload = nil`（"城市名 + --° + 暂无数据"，AC-C6，绝不冒充）。

**泛化规则（逐条）**：

1. **把归属判据集中成一个纯函数**，所有源共用，不再散落比较：
   ```swift
   // Core/Logic（新）：纯逻辑，随主 App target 编译，可 @testable 单测
   enum PayloadOwnership {
       static func isOwned(location: LocationInfo, by city: City) -> Bool {
           city.id == City.makeID(latitude: location.latitude, longitude: location.longitude)
       }
   }
   ```
2. **逐源独立校验、逐源独立降级**：主载荷不匹配 → 主载荷 nil；某副源不匹配 → **仅该副源 nil**，其余照常渲染（**不要 all-or-nothing**）。
3. **主载荷的 R-C2 语义逐字保留**：主快照不归属时，entry 仍走"城市名 + --° + 暂无数据"（`WeatherEntry.swift:20-27` 语义不变）。
4. **归属键恒为 `city`**（来自 `WidgetCityResolver.resolve(...)`，`WeatherProvider.swift:92`），**永不**用 `payload.snapshot.location` 反推目标城市（否则固定城市实例会串到别的城市数据）。
5. Widget **只读**：`makeEntry` 四步（L87-112）保持"无网络、无同步阻塞"；新源只是"多读一个 key"，不得引入任何 fetch。

### 2.4 三处节流在多源不同节奏下的状态

现状节流：

| 节流 | 位置 | 值 | 作用域 |
|---|---|---|---|
| 主载荷新鲜度 | `WeatherViewModel.swift:60`（`freshnessWindow`），被 `refreshIfNeeded()` L269-274 消费 | 15 min | 主载荷 |
| Widget 常规刷新 | `WeatherProvider.swift:62` | 45 min | 时间线 |
| Widget iOS16 兜底条目 | `WeatherProvider.swift:71` | 30 min | 时间线 |

多源并存后的规则（避免"请求倍增"）：

- **规则 1**：15 min 窗口**只治理主载荷**。新源**不得**复用主载荷的 `updatedAt`；用自己信封里的 `updatedAt`（§2.2.1）判定。
- **规则 2**：**只有节奏 ≤ 主节奏（≤15 min）的源**才挂到 15 min tick 上自动刷。慢源/贵源（seasonal、多模型气候、往年 lookback、卫星辐射）**不挂 tick**，改为**事件驱动**（进页面 / 用户点按），并受 §4 配额守卫约束。
- **规则 3**：Widget 侧**永不**触发任何多源网络请求；新源由 App 写入，Widget 只渲染"最近一次且归属命中"的值，其节奏与 App 的刷新节奏解耦。
- **规则 4**：`reloadAllTimelines()`（`WeatherViewModel.swift:177`/L317）当前只在**主天气成功**时调用。若某副源也要上 Widget，需在该副源**成功落盘后**也 `reload`，但**必须合并/节流**（同一 tick 内多源成功只 reload 一次，避免刷新风暴）。
- **落地物**：在 VM 侧维护一张"节奏注册表"（每源 `(key, cadence, lastUpdated)`），`refreshIfNeeded` 遍历决定"哪些源本轮该刷"。这样"多源不同节奏"从"每次全刷"变成"按需定向刷"。

---

## 3. 失败隔离纪律

### 3.1 泛化 `loadAir` 先例（`WeatherViewModel.swift:341-351`）

`loadAir` 的四条隔离纪律，把它抽成**新链路必须逐条满足**的规则：

| # | 纪律 | `loadAir` 出处 | 新链路要求 |
|---|---|---|---|
| 1 | **自带 Task**，不在主 `do` 块内 `await` | L181 / L320 `Task { await loadAir(for:) }` | 同：`Task { await loadX(for: city) }`，与主链路**并行**、**时序解耦** |
| 2 | **catch 只置本槽位 nil**（或保留上次好值），**绝不触碰 `state`** | L347-350 `airQuality = nil` | 同：只写 `xValue`，**禁止** `state = .failed` |
| 3 | **成功赋值前 `selectedID` 守门**（丢弃切城后的过期结果） | L345 `guard directory.selectedID == city.id else { return }` | 同（P1-A 纪律平移） |
| 4 | **不 rethrow**：错误无法回流到主链路 catch（L186） | actor 抛 `WeatherError`，VM 侧吞掉 | 同 |

### 3.2 规则：新链路**永不**触碰 `state`（成文条款）

- 新链路的"自己的槽位" = VM 的 `private(set) var xValue: X? = nil`（变体 b）或页面的 `@State phase`（变体 a）。**只有主天气链路**可以写 `state`（`.loading/.loaded/.failed`）。
- 新链路失败 → 其 UI **整块隐藏或降级**（沿用 `airQuality == nil` 整卡不渲染、`ContentView.swift:162` 的模式），**不弹错、不切页、不影响主屏**。
- 与 `HistoricalWeatherView` 的页内降级（`Phase.failure` + 重试按钮）语义一致。

### 3.3 B2 多源偏好与"凭据缺失/被拒"的降级

- **偏好序**：和风（QWeather，需自带 key）**主** → Open-Meteo **补缺**。
- **凭据缺失（无 key）**：**不**发起和风请求，直接走 Open-Meteo 路径；UI 显示 Open-Meteo 派生值。**"缺失"不是失败**，不报错、不打红。
- **凭据存在但被拒（401/403）**：视为**瞬态源失败** → 该字段回退 Open-Meteo；并**本会话内禁用和风**（避免每 tick 重试轰炸）。
- **429（限流）**：进入**冷却期**（如 ≥10 min 不重试），期间一律回退 Open-Meteo。
- **逐字段降级，非逐请求**：例如生活指数——和风返回则用官方值，否则用本地估算（`LifeIndexEngine`，`ContentView.swift:177`）；**某字段在主源缺失时独立降级**，不影响同请求内的其他字段。
- **来源标注（禁静默混源）**：每个字段/载荷携带来源枚举（如 `official` / `openMeteo` / `localEstimate`），UI 可标注"官方 / 估算 / 本地估算"。这是 `AirQualityMapper` "不冒充读数"（L44-53 注释）纪律的平移。
- **Widget 永不接触凭据**：key 只在主 App 进程内使用；进入共享容器的只有**合并后的结果**。

---

## 4. 配额守卫（Open-Meteo 10,000 次/日预算）

### 4.1 请求倍增风险（核心危害）

Open-Meteo 预算 = 10,000 调用/日。**代价按"请求的模型权重"累加**，不是每次请求都算 1：

| 端点/模型组合 | 等价调用数 | 占日预算 |
|---|---|---|
| 多模型长期气候（climate） | **1844.5** | ≈ 18.4% |
| 集合预报（ensemble） | **4.0** | 0.04% |
| 季节预报（seasonal） | **1.3** | 0.013% |

→ **单次气候请求即吃掉近 1/5 的全天预算；约 5 次即耗尽**。故：

- **贵端点必须"用户触发"或"默认关"**：凡权重 ≥ 阈值（建议 **≥4.0**，即 ensemble 及以上）的端点，**默认 OFF**，且**仅用户显式点按**才发起（绝不在 15 min tick、冷启动、Widget、后台触发）。
- **便宜端点**（权重 ≤ ~1.5）可自动刷，但仍**过守卫**。

### 4.2 守卫设计（新 Core 文件 `Core/Logic/QuotaGuard.swift`）

- 纯逻辑、无 IO、**时钟注入**（Core 禁内部 `Date()`）。
- **代价模型**：`static func weight(endpoint:model:) -> Double`，按上表返回等价调用数。
- **预算账本**：persist 到 App Group（`zs.weather.quota.<yyyy-mm-dd>` 或滚动 24h），按端点分桶计数，跨启动保留。
- **硬门**：贵端点 GET 前先 `guard.check(cost:)`；超预算返回 `.denied(reason:)`，链路渲染自己的降级态（**不触碰 `state`**），提示"今日额度已用尽，明日再试"。
- **预留头寸**：保留 ~10% 预算给"用户手动请求"，防止后台 tick 饿死手动请求。
- **用量可视化**：开发者模式页展示当日各端点用量（呼应 B1 的 developer mode）。

### 4.3 往年同日 lookback 的**按年节流**（archive loop）

约束：`past_days` 上限 92；ERA5 **滞后 ~5 天**。故"往年同日"**不能一次请求**，必须**逐年 loop `start_date`/`end_date`**。

- **逐年请求**：对每一年 Y，计算目标日历窗（如"今天 ± 数日"），用**显式 `start_date`/`end_date`** 调 Archive——`ArchiveEndpoint.url(latitude:longitude:startDate:endDate:)`（`ArchiveEndpoint.swift:34-46`）**本就支持任意区间**，无需改端点。
- **节流**：**串行**（非并行）+ 请求间最小间隔（建议 ≥1s）+ 单次用户动作**年份上限**（建议 ≤10）。
- **滞后偏移**：沿用 `HistoricalWeatherView.swift:166-170` 的"往前多留余量"约定（-6/-13），避开 ERA5 的 ~5 天滞后。
- **缓存**：按 `(城市, 年窗)` 缓存，TTL 长（建议 ≥7 天，ERA5 稳定），再次打开不重复命中。
- **配额**：**N 年 = N 次 archive 调用**，逐年计数；超日上限则拒绝。archive 单次虽便宜，但 N 年**可倍增**，守卫必须按 N 计。
- **失败隔离**：某一年失败 → 该年显示"暂无"，**继续 loop**；绝不因单年失败整体 abort，绝不触碰主 `state`。

---

## 5. 兼容与纪律清单（每条都必须满足）

| # | 条款 | 依据 / 落点 |
|---|---|---|
| 1 | 新载荷字段一律 **`Optional` + 合成 Codable**（默认 `nil`），照抄 `daily: [DailyForecast]? = nil`（`WeatherSnapshot.swift:63`）及其 L54-57 注释 | R3 |
| 2 | **禁止**手写 `init(from:)`；**禁止** `payloadVersion` | `WeatherSnapshot.swift:57`（明文禁止） |
| 3 | **禁止**把既有非可选字段改成可选（破坏性）、**禁止**删字段 | 旧缓存兼容 |
| 4 | `supportedFamilies` **只增不减** | R2 |
| 5 | `project.yml` **零改动**：不加 target、不加依赖、不改 build setting；新文件**必须**落在已被挂载的目录（`Core/`、`ZhishengWeather/`、`ZhishengWeatherTests/`）内 | R1 / `project.yml:84,103` |
| 6 | 新文件**不得**放进"仅靠 `project.yml` 引用"的新目录（否则触发 R1） | R1 |
| 7 | **JSONP 台风解析**（typhoon.nmc.cn）：`URLSession` + 剥离 JSONP 外壳 → `JSONDecoder`，**手写解析器放 `Core/`，零新增依赖** | R1（禁新依赖） |
| 8 | Core 纪律：`import Foundation` 唯一、禁 UIKit/UIApplication、禁内部 `Date()`、禁 `try!`/`fatalError` | Core 文件头 |
| 9 | DTO 整键可选；mapper 层净化（负值/NaN → nil），照抄 `AirQualityMapper` L44-53 | 数据纪律 |
| 10 | 错误**收敛到** `WeatherError`（`WeatherProviding.swift:11`），不新建错误类型 | §1.2 |
| 11 | 新 App Group key **只在 `AppGroup.swift` 定义**，别处引用常量，**禁止内联字符串** | `AppGroup.swift` 头注释 |
| 12 | 所有共享写路径**必须**走 `verifyWritten`（`AppGroupStore.swift:46-50`） | §2.2 |
| 13 | 失败路径"绝不冒充"（数据缺失 → 显示 `--` / 隐藏，不显示 0） | `ContentView.swift:464-468` 纪律 |

---

## 6. 既有缺陷接线点（精确一行修复 + 需扩展的测试）

### 6.1 D-1 星标置顶未生效（`displayCities` 死代码）

- `Core/Logic/CityDirectory.swift:156-160` 定义了 `displayCities`（收藏置顶、组内稳定排序）。
- `ZhishengWeather/CityListView.swift:42` 却遍历 `viewModel.directory.cities` → **星标不置顶**。
- **一行修复**：
  ```swift
  // CityListView.swift:42
  ForEach(viewModel.directory.displayCities) { city in   // 原：viewModel.directory.cities
  ```
- **⚠️ 必须连带的坑（否则修一个坏一个）**：`displayCities` 是**重排后的展示序**，而 `.onMove`（L45-47）/`.onDelete`（L48-50）给出的 `IndexSet`/`offsets` 是**展示序下标**。直接用这些 offset 去调 `viewModel.moveCities(fromOffsets:)`（`WeatherViewModel.swift:253-256`）或 `remove`(id 版) 会**错位**（`CityDirectory.move` 操作的是 `cities`，`CityDirectory.swift:143-145`）。修法二选一：
  - **(推荐 a) 列表侧先把展示 offset 映射为 id**：`offsets.compactMap { directory.displayCities[$0].id }`，再走 **id 基**动作（`remove(id)` 已是 id 基；`move` 需要新增"id 基拖动"或在 VM 内把 offset 反查回 `cities` 下标后再调 `directory.move`）。
  - (备选 b) 仅在**非编辑态**用 `displayCities` 渲染，编辑态回退 `cities`（规避错位，但编辑时顺序"跳变"）。
- **需扩展的测试**：
  - `ZhishengWeatherTests/CityDirectoryFavoriteTests.swift`（已存在，纯逻辑）：补"重排后 offset→id 映射"断言；若新增 `CityDirectory.indices(ofIDs:)` 之类纯函数则直接单测。
  - `ZhishengWeatherTests/CityDirectoryTests.swift`：补"收藏置顶后按 id 删除/移动命中正确城市"。

### 6.2 D-4 异地城市时区未生效（`timeFormatter` 未设 `timeZone`）

- `City.timeZoneIdentifier` 已持久化：`Core/Networking/GeocodingMapper.swift:31`（`City.swift:28` 定义）。
- 生产代码里**只**把它当副标题兜底标签：`CityListView.swift:196-197`。
- 真正渲染时间的格式器**未设时区**：
  - `ZhishengWeather/ContentView.swift:440-443` `dateFormatter`（`"M月d日 HH:mm"`）——**无 `timeZone`**。
  - `ZhishengWeather/ContentView.swift:448-451` `timeFormatter`（`"HH:mm"`）——**无 `timeZone`**（`ContentView.swift:225` 用它渲染 `fetchedAt`）。
  - 另有多处 formatter 同样未设：`DailyForecastRow.swift:170-184`、`SettingsView.swift:90-92`、`HourlyStrip.swift:56-59`、Widget 侧 `WidgetShared.swift:16-34`、`LargeWeatherView.swift:315-317`。
- **关键约束**：`WeatherSnapshot.location` 是 `LocationInfo`（`Core/Models/LocationInfo.swift:11`，**无时区字段**）→ 时区**不能**从快照拿，只能从**选中的 `City`**拿（`directory.selectedCity?.timeZoneIdentifier`）。
- **推荐最小修复**：
  1. VM 暴露一个派生属性（不改模型、不动载荷）：
     ```swift
     // WeatherViewModel.swift（新增计算属性）
     var selectedTimeZone: TimeZone? {
         directory.selectedCity?.timeZoneIdentifier.flatMap { TimeZone(identifier: $0) }
     }
     ```
  2. 把渲染时间的 formatter 从 `static let` 改为**按所选时区构造**（或运行时覆盖 `formatter.timeZone`）：
     `ContentFormatter.fmt(for: viewModel.selectedTimeZone)`，内部 `formatter.timeZone = tz ?? .current`（nil → 设备时区，保持既有行为）。
  3. 建议抽一个 Core 纯函数集中时区解析，便于单测：
     ```swift
     // Core/Logic（新）
     enum WeatherTimeFormatter {
         static func timezone(for city: City?) -> TimeZone { city?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
         static func string(_ date: Date, format: String, in tz: TimeZone, locale: Locale = Locale(identifier: "zh_CN")) -> String { ... }
     }
     ```
- **需扩展的测试**：新增 `WeatherTimeFormatterTests`（Core 纯函数）：同一 `Date` 在 `"Asia/Shanghai"` 与 `"America/New_York"` 下格式化结果**必须不同**；`nil` 时区 → 回退设备时区。VM 侧补 `selectedTimeZone` 随选中城市变化、`nil` 回退的断言（可并入既有 VM 测试）。

---

## 7. 风险表（按危害排序）+ CI-only 验证说明

| 排序 | 风险 | 级别 | 缓解 | 验证锚点 |
|---|---|---|---|---|
| 1 | 多模型长期气候请求耗尽 10k 预算 | 🔴 高 | §4：贵端点默认 OFF + 仅用户触发 + `QuotaGuard` 账本 + 预留头寸 | `QuotaGuard` 纯逻辑单测（权重/超限/预留） |
| 2 | 手写 Codable / 引入 `payloadVersion` 击穿旧缓存 | 🔴 高 | §5 条款 1-3；代码评审 + 清单 | 扩展 `WeatherSnapshotCacheCompatTests`：喂"无新键的旧形状 JSON"必须解码成功 |
| 3 | `displayCities` 重排导致 move/delete **错位** | 🔴 高 | §6.1 修法 a：offset→id 映射 + id 基动作 | `CityDirectoryFavoriteTests` / `CityDirectoryTests` 补映射断言 |
| 4 | 多源 Widget **归属串号**（A 城源显示到 B 城组件） | 🟠 中高 | §2.3：集中归属判据 + 逐源独立 nil | 扩展 `WidgetCityResolverTests` + 新 `PayloadOwnership` 单测 |
| 5 | 多源 × 多节奏 → **请求倍增** | 🟠 中 | §2.4：逐源 `updatedAt` + 节奏注册表 + 慢/贵源事件驱动 | VM 节奏表单测（哪些源本轮该刷） |
| 6 | 新链路失败**污染 `state`** | 🟠 中 | §3：`loadAir` 四纪律 + 独立槽位 | 镜像 `WeatherViewModelAirTests`：新源失败后 `state` 仍 `.loaded`、槽位 nil |
| 7 | JSONP 台风解析器对非标响应脆弱 | 🟠 中 | §5 条款 7：防御式解析 + fixture | `TyphoonParserTests`：喂真实/畸形 JSONP fixture，畸形 → 空（不崩） |
| 8 | 和风凭据缺失/被拒未正确降级 | 🟠 中 | §3.3：缺失直走 OM、401/403 本会话禁用、429 冷却、逐字段降级 | 多源偏好/降级单测（注入假凭据态） |
| 9 | 往年 lookback 逐年串行延迟 | 🟡 中低 | §4.3：年份上限 + 缓存 + 渐进展示 | loop 节流 + 缓存命中单测 |
| 10 | 误删 `supportedFamilies` 某族 | 🟡 低 | R2 + 评审守则 | 人工核对（无自动测） |
| 11 | 新文件落在未挂载目录 → R1 被破 | 🟡 低 | §5 条款 5-6 | 目录归属评审（`Core/` 或 `ZhishengWeather/`） |

### 7.1 无本地编译器下的验证方式（**CI-only 门禁**）

本机为 Windows，无 Xcode，**唯一编译/测试门禁是 GitHub Actions macOS CI**。据此：

1. **每条新链路的 ①-⑤ 必须至少被一个 XCTest 覆盖**——因为 CI 会跑 `ZhishengWeatherTests` bundle，**没有测试覆盖的新文件等于没有验证**。可复刻的测试模板：
   - 端点请求面：`AirQualityEndpointTests.swift`（域名/字段/`timezone=auto`/无多余参数）。
   - DTO 解码边界：`AirQualityResponseTests.swift` / `OpenMeteoDecodingTests.swift`（整键缺失、null 元素、块缺失）。
   - 映射器：`AirQualityMapperTests.swift`（含负值/NaN 净化）。
   - 链路隔离：`WeatherViewModelAirTests.swift`（Stub 注入，断言失败不污染 `state`）。
   - 兼容：`WeatherSnapshotCacheCompatTests.swift`（旧形状 JSON 解码成功）。
2. **新链路默认 OFF / 特性开关**：让"写坏的新链路"**不能**拖垮主链路编译与既有测试，CI 红/绿可定位到具体新链路。
3. **测试不得联网**：全部纯构造 + Stub（沿用 `WeatherViewModelAirTests` 的 `StubAirService` / `StubWeather` 模式），保留 CI 确定性。
4. **服务 actor 的 `init(session:)` 可注入**（§1.2），使端到端逻辑（decode+map）能在 CI 上以本地 `URLProtocol`/Stub 覆盖，无需真机。
5. **真机/预览验收本轮不在门禁内**：凡"仅真机可见"的项（Widget 渲染、定位、主题氛围）记为**发布前人工冒烟**，与本轮 CI 门禁分离。

---

## 附：冻结范围 ↔ 链路变体映射（供 Engineer 分解任务）

| 冻结项 | 建议变体 | 是否可跳步骤⑥ | 是否受 §4 配额约束 |
|---|---|---|---|
| 遥测补全（visibility/dew_point_2m/cloud_cover/wind_gusts_10m） | 主链路参数扩展（`OpenMeteoEndpoint` 加字段） | 否（并入主链路） | 低（并入既有请求） |
| minutely_15 短时降水卡 | 变体 b 或 (a) | 视是否主屏常驻 | 低 |
| 往年同日 lookback | 变体 (a) 页面切片 | **是**（Archive 先例） | **是（按年节流）** |
| Himawari-9 卫星辐射 | 变体 (a) | **是** | 中 |
| flood / marine | 变体 (a) | **是** | 中 |
| ensemble 概率 | 变体 (a/b) | 视消费面 | **是（权重 4.0，需用户触发）** |
| seasonal 预报 | 变体 (a) | **是** | **是（权重 1.3）** |
| 多模型长期气候 | 变体 (a) | **是** | **是（权重 1844.5，必须默认关 + 用户触发）** |
| 台风轨迹（JSONP） | 变体 (a) + 手写解析器 | **是** | 低 |
| 纯文本 Tips / 开发者模式 / what's-new | 纯本地（无网络链路） | N/A | 无 |
| B2 和风（nowcast/预警/生活指数/多源） | 变体 b + §3.3 降级 | 否（若主屏消费） | 中（和风自有配额另计） |
| 街道级定位 | 扩展 `Geocoding` 消费 | 否 | 低 |
| B3 UI 氛围层（主题三档/背景/自绘图标/横屏/卡组） | 纯 UI，无新数据链路 | N/A | 无 |
