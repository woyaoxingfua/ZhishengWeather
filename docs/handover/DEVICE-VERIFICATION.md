# 真机验收清单（DEVICE-VERIFICATION）

> **面向谁**：拿到一份 CI 绿过的 IPA、装到真机上的开发者。
> **目标**：1 小时内跑完，每条都能得出「是 / 否」结论。
> **本清单只写可判定的操作与观察点**。「看起来正常」「确认能工作」这类无证明力的写法一律不写。

---

## 0. 先读这一节：三条会让人误判的前提

### 0.1⚠️ 当前 HEAD（`d715851`）**从未被 CI 编译过**，装不了包

| 项 | 事实 | 依据 |
|---|---|---|
| HEAD 提交 | `d715851` feat(R2): 像素级平移机制（路径 A） | `git log -1` |
| HEAD 的 CI run 数 | **0** | `GET /actions/runs?head_sha=d715851...` → `total_count: 0` |
| HEAD 是否已 push | **未 push**（`origin/ios` 仍停在 `505b7dc`） | `git branch -r --contains d715851` → 空 |
| 最近一次 CI（run 123，`505b7dc`） | **失败**，step 7「Run unit tests (simulator)」 | `GET /actions/runs/37491931134/jobs` |
| 失败根因（编译错误） | `Core/Networking/WeatherCnAlarmResponse.swift:128` `type of expression is ambiguous`；`:135` `extra argument 'at' in call` | run 123 check-run annotations |

-该两处错误已在本地提交 `054781c` 修掉（`git merge-base --is-ancestor 054781c HEAD` → 是），
  **但 `054781c` 与 `d715851` 都未 push，因此都没有 CI 结论。**
- ⇒ **本清单的第 1 步不是操作 App，而是先确认 CI 绿。** 在 CI 绿之前，下面所有条目都无法执行。
- **不要**因为「本地提交信息里写了『已修两处编译错误』」就认为现在能编译。唯一门禁是 GitHub Actions 的结论。

### 0.2 ⚠️ 雷达纠偏**不能靠切档验证**，切档看不出差别是预期行为

这一条必须先讲清楚，否则 3.x 全部会被误判成「开关坏了」。

现有纠偏走的是「瓦片中心 → 纠偏 → 反算索引」（`ZhishengWeather/RadarMapCard.swift:135` `correctedTileCoordinates(for:)`）。
瓦片中心距最近索引边界**恒为半格**；z7 的半格 ≈ 156 km，而 GCJ-02 境内最大偏移 ≈ 663 m
⇒余量约 236 倍，纠偏后的点必然仍落在同一格内，**索引不变**。
纯函数判据在 `Core/Logic/CoordinateTransform.swift:810` `canCorrectionChangeTileIndex(zoom:offsetMeters:)`
与 `:822` `correctionIsInertAcrossRadarZooms(maximumOffsetMeters:)`（`RadarTileZoomRange` = 4...7）。

⇒ 三个档位在 z4–z7 **产生完全相同的瓦片 URL，渲染逐像素一致**。

- **所以「切三档看回波是否对齐」这个验收方法在原理上无效**，不是 bug。
- 替代办法见 **3.2**，那里给了一条真正能判定的替代路径。

### 0.3 ⚠️ 像素级平移**默认关闭，且当前没有 UI 可以打开**

`d715851` 实现了绘制期平移（`ShiftedTileOverlayRenderer`，`RadarMapCard.swift:292`，走
`MKOverlayRenderer.draw(_:zoomScale:in:)` 里的 `CGContext.translateBy`，因为 `MKTileOverlayRenderer`
官方页确认没有任何平移 API）。

但：

| 事实 | 依据 |
|---|---|
| 档位偏好键 `zs.radar.pixelShiftMode` | `RadarMapCard.swift:254` |
| **全仓没有任何 `RadarPixelShiftStore.set(...)` 调用点** | `grep -rn "RadarPixelShiftStore.set" --include=*.swift .` → **无命中** |
| 设置页只有「GCJ-02 纠偏」三档 Picker，**没有平移档位 UI** | `ZhishengWeather/SettingsView.swift:274-297`（该Section 内无平移 Picker） |
| ⇒ 平移档位在真机上**只能是 `.off`**，且无任何手段可改| 上一行两条的推论 |

⇒ **「平移机制开启与关闭的差别」这一条在当前构建上无法执行**，3.3 如实标注。
不要把「UI 上显示『未平移 · 不平移（默认）』」当成「机制被验证过」。

---

## 1. 前置门禁（不做这步，后面全都跑不了）

**操作**：把 `ios` 分支 push 到远端，等 GitHub Actions 的 `iOS Build` 跑完。

**判据**（三条全中才算过）：

1. 该次 run 的 `head_sha` == 你要装的 commit（不是 `505b7dc`）。
2. run `conclusion` == `success`。
3. 「Package unsigned IPA」这一步是 `success`（**不是 skipped**）。

**若失败**：先看 step 7 的 annotations。本清单写作时它报的是
`Core/Networking/WeatherCnAlarmResponse.swift:128` / `:135` 编译错误，
排查起点 = 该文件 `WeatherCnAlarmListResponse.Row.init(from:)`（`:126`）。

> 装包后**第一件事**是核对版本号（见 4.1），确认装的确实是这一版。

---

## 2. 小组件（6 条）

前置：主 App 已装好，至少完整打开过一次并下拉到主屏（让主 App 完成一次取数）。

### 2.1 能添加三个尺寸的桌面小组件 — **本清单可判定**

**操作**
1. 长按桌面空白处→ 左滑 → 「添加小组件」→ 搜「枳生」（或按 widget 名）。
2. 分别添加 **Small / Medium / Large** 各一个。

**判据**：三个尺寸**都能加进桌面**。任何一个尺寸在列表里缺失、或添加后桌面不出现图标卡片 → 失败。

**若失败，先查**：`ZhishengWeatherWidget/ZhishengWidgetBundle.swift:62` `supportedFamilies([...])`
——该处应同时含 `.systemSmall/.systemMedium/.systemLarge`。少了哪个就是哪个缺失。

---

### 2.2 编辑界面里候选列表非空（34 个内置城市 + 2 个哨兵）— **本清单可判定**

**操作**：长按任一小组件 → 「编辑小组件」→ 点「城市」→ 展开城市列表，数一下。

**判据**：
- 列表**第一项**是「跟随 App」、**第二项**是「当前位置」（顺序固定）。
- 第一项之后有**34 个真实城市**条目（含「北京」）。
- 计数方式：以「跟随 App」和「当前位置」为基准，数到列表末尾的城市条目 = 34。

**若失败，先查**：`Core/Logic/WidgetCityQuery.suggestedEntities()`（`Core/Logic/WidgetCityIntent.swift:185`）
与 `WidgetBuiltInCities.cities`（`Core/Logic/WidgetBuiltInCities.swift:56`）。
数量对不上时用 `ZhishengWeatherTests/WidgetBuiltInCitiesTests.swift:19`
（断言 `count == 34`）作为唯一口径。

---

### 2.3 选具体城市后能否取到数 — **本清单可判定（这是核心一条）**

⚠️ **不要用默认状态判断**。默认哨兵走 `.followApp` 分支，而侧载产物上 App Group 容器恒不可用
（`Core/Storage/AppGroupStore.swift:200` `isSharedContainerAvailable` 用
`containerURL(forSecurityApplicationGroupIdentifier:)` 显式探测）→ 默认永远无城市 →
「默认没数据」是**预期行为**，与功能好坏无关。

**操作**
1. 编辑小组件 → 「城市」→ 选一个**具体城市**（建议选「杭州」，代码里就是拿杭州当判例的）。
   选完点完成，等待。
2. 等 45 秒以上（`WeatherProvider.timeline` 的刷新策略是 `.after(now + 45min)`，
   见 `ZhishengWeatherWidget/WeatherProvider.swift:104`；期间也可点小组件右上角的 ⟳ 强制刷新）。

**判据 —— 三态互斥，看标题 + 现象位即可分辨**（这套判据来自
`Core/Logic/WidgetCityIntent.swift:45-51`，与代码同源）：

| 标题 | 现象位 | 结论 |
|---|---|---|
| 标题为具体城市名（如「杭州」）+ **真实温度数字** | 正常天气描述 | ✅ **全通** |
| 标题为具体城市名 + `--°` | 「未能获取天气」 | ❌ 配置读回**成功**、取数链路**失败** |
| 标题是 `—` | 「暂无数据」 | ❌ 配置读回**仍然被替换成默认值**（回退到哨兵） |

- 三个 family 的标题都要各看一眼，三者应一致。
- **只要有一个 family 出现 `--°`，就是失败**，不要因为「另外两个好了」放过。

**若失败，先查**：
- 若是第3 行（标题 `—`）：配置回读链路 → `Core/Logic/WidgetCityIntent.swift:314` 的
  `init()`（这是已修过的缺陷，注释在 `:281-313`）。若 init 已在但仍如此，说明是系统持久化层另有问题。
- 若是第 2 行（标题对但 `--°`）：取数链路 → `Core/Logic/WidgetDataResolver.resolve`
  （`:64`，L1 分支 `:121`）与 `WidgetWeatherService` 的 8s 超时。
- 两者都像时：先在设置页看「小组件自查」区（4.3）。

---

### 2.4 Large 空态是否**只**显示一个如实状态（不是四句「暂无」）— **本清单可判定**

`505b7dc` 修的就是这条：原来无条件渲染三个数据区块，各落一句硬编码兜底，
加上 hero 的状态句 = **同屏四句「暂无」**，把「什么都没取到」伪装成「只缺几项」。
现在空态下三个区块整段不渲染（`ZhishengWeatherWidget/LargeWeatherView.swift:74` `if entry.resolution.hasPayload`）。

**操作**：编辑小组件，把城市改成「跟随 App」→ 等它变成空态 → 盯着 Large 卡片逐字读全屏文字。

**判据**：
1. 屏幕上**「暂无」二字总共只出现 1 次**（在现象位）。
2. **看不到**「未来三天」「未来四小时」「2×3 指标网格」这三个区块标题。
3. **看不到**三句硬编码兜底：「暂无逐日数据」「暂无逐时数据」「暂无指标数据」。
4. 底部有且只有一行可操作提示：「长按小组件 → 编辑，选择城市」
   （`Core/Logic/WidgetCopy.swift:150`）。

**若失败，先查**：`LargeWeatherView.swift:74` 的 `hasPayload` 门控，
以及 `Core/Logic/WidgetCopy.swift:144` `hintText`。

> **读代码确认的一个残留问题**（不是验收项，供你判断要不要提单）：
> Large 空态下，`updateText`（`:325`）在无载荷时返回的就是 `conditionText` 本身
> （`WidgetCopy.updateText` 的 `:129` 直接 `return conditionText(resolution:)`），
> 而 `conditionText` 又渲染在 hero 里（`:148`）。⇒ **空态下同一句状态话会在屏幕上出现两次**
> （头部时间位一次 + hero 一次）。这不是「四句暂无」那个 bug，但确实是同一状态句重复一次。

---

### 2.5 城市配置能否持久（重启 / 跨进程后还在）— **本清单可判定**

**操作**
1. 把 Small 小组件配置成「杭州」。
2. **完全杀掉主 App**（从多任务卡片上滑掉，不要只切后台）。
3. 等 60 秒后回桌面看小组件。

**判据**：标题**仍是「杭州」**，且不是退回「跟随 App」或 `—`。

**若失败，先查**：这不是代码里能自证的 —— 系统按 per-instance 存配置，
若读回失败，回到 2.3 的第 3 行判据去查 `WidgetCityQuery.entities(for:)`
（`Core/Logic/WidgetCityIntent.swift:234`）。⚠️ 注意该方法末尾有个 `.followApp` 兜底
（`:247`），它会**改写**用户的选择而不只是显示错 —— 所以「配置被悄悄换成跟随 App」
正是这条的预期失败形态。

---

### 2.6 「当前位置」哨兵是否恒出现、配置路径零定位 — **本清单可判定（部分）**

**操作**：编辑小组件 → 点「城市」，**不选任何项**，只观察列表。

**判据**：
- 「当前位置」出现在候选列表里，**且排在第 2 位**。
- 完全**撤销**定位权限（设置 → 隐私 → 定位服务 → 关掉本App）后再打开编辑界面：
  「当前位置」**仍然在列表里**（不按权限动态隐藏，这是AC-C15② 的设计）。

**若失败，先查**：`WidgetCityEntity.currentLocation`（`Core/Logic/WidgetCityIntent.swift:120`）。

**这条只能判到「候选列表的呈现」**。「当前位置」被真正选中后，timeline 里到底有没有取到点，
判据见 **5.3** —— 那个才需要真机定位权限，且本清单无法保证一定触发。

---

## 3. 雷达（8 条）

前置：设置页 → 「雷达回波（调试）」Section 存在（`SettingsView.swift:274`）。

### 3.1 雷达卡是否出现在主屏、四态都不空白 — **本清单可判定**

**操作**：下拉主屏，滚到「降水雷达」卡。

**判据**（4 条全中）：
1. 卡标题是「降水雷达」，右上角有一句**结论句**（不是空白）。
2. 地图区**有底图**（不是白屏、不是纯色、不是一直转圈）。
3. 左下角有署名「Weather data by RainViewer」（许可硬要求，见 `RadarMapCard.swift:734`）。
4. 地图区**左上角**有降级说明句，或因为是真回波态而**没有**这句。
   两者必居其一，**绝不允许整块空**。

**若失败，先查**：`ZhishengWeather/RadarMapCard.swift:655` `degradedOverlayText`
（明确要求 `.radarUnavailable` **绝不能返回 nil**）与 `:616` 的加载中分支
（`if model.isLoading && !model.hasTimedOut` —— 若一直转圈不消失，是超时兜底没生效，
查 `RadarCardModel.hasTimedOut`，`:62` `loadTimeout = 12` 秒）。

---

### 3.2 纠偏方向：**不要用切档来测** — 换用可判定的替代办法

**⛔ 作废的验收方法**：「三档切一遍，看回波是否对齐」——
见 0.2，它在原理上测不出任何东西（三档 URL 完全相同）。

**替代办法 A（推荐，唯一能定方向的真机手段）**

**操作**：找一个**回波与海岸线/省界/大型建筑物边界重合**的时刻（回波强度大、边界清晰），
在设置页把「GCJ-02 纠偏」切到「纠偏（假定 MapKit 未处理）」，
然后把地图放到**该边界**上，肉眼比对**回波边缘与底图边界是否重合**。

**判据**：把地图缩放到**最大**，让该边界横跨屏幕：
- 回波边缘与底图边界**重合** → 方向判为「需纠偏」（即当前默认档 `.autoAssumeNotApplied` 正确）。
- 两者**错开且错开方向稳定** → 记下错开方向，方向判为「不需纠偏」。
- 两者错开但**每次拖动地图错开方向会变** → 不是纠偏问题，是别的问题（回波本身有偏移/时延），停止这条。

**⚠️ 判据本身的局限（必须知道）**：真偏移折合屏幕像素为
z7 北京 ≈ 0.45 px、广州 ≈ 0.51 px（@1x）；@2x 为 0.70 / 0.93 px。
**这远低于肉眼判别极限**，所以：
- 你**大概率量不出**对错；
- 你若量出「错开」，很可能量的是回波本身的形态误差，不是纠偏。

⇒ **建议按下面的方式处理，不要假装测出来了。**

**替代办法 B（诚实的替代结论，推荐作为落档口径）**

**判据**：把「纠偏方向」当**未经验证**的已知未知项落档，而不是产出一个假的结论。
具体地：保留 UI 上现有那句「纠偏方向未验证」（`RadarMapCard.swift:558`、`:560`），
并在验收记录里写明：

> 纠偏方向未验证。原因：z4–z7 上纠偏是恒等变换（切档不可测）+ 真实偏移 < 1 设备像素（肉眼不可辨）。
> 当前默认档 `.autoAssumeNotApplied` 是**因为无害而保留**，不是因为已被证实
> （依据见 `Core/Logic/CoordinateTransform.swift:164-202`，其中依据 2「失效方向不对称」
> 已被本轮推翻，依据 1 仅为旁证）。

**⇒ 本清单无法判定纠偏方向。** 见文末「无法确定的项」。

**若失败/ 若你想真要定它**：唯一有希望的换手段是**放大截图**——
截屏后在图像工具里量回波边缘与底图边界的像素距离，与
`CoordinateTransform.pixelShiftProbe` 算出的理论像素当量比对。
但这需要**当天有强回波**，属「需要特定条件」，见 5.1。

---

### 3.3 平移开启与关闭的差别 — ❌ **当前构建无法执行（无 UI 入口）**

**为什么做不了**：见 0.3 —— `RadarPixelShiftStore.set` 全仓无调用点，设置页没有平移 Picker。
真机上档位恒为 `.off`。

**当前唯一能看到的**（这是个**弱**判据，只能证明读取通路在，不能证明机制在）：

**操作**：主屏雷达卡，看地图下方那行读数。

**判据**：显示「未平移 · 不平移（默认） · 纠偏方向未验证」。
即 `.off` 分支如实显示、**不谎称已纠偏**（`RadarMapCard.swift:559`）。

- 这条**通过**只说明：档位读取通路通+ 文案诚实。
- **它不说明**平移机制可用。要验机制必须改代码加 Picker，本清单不碰Swift 代码。

**若失败，先查**：`RadarMapCard.swift:254` 的键 `zs.radar.pixelShiftMode`
与 `RadarPixelShiftStore.current()`（`:257`）；非法值回落 `.off` 是**安全默认**，回落不是 bug。

---

### 3.4 平移量读数是否为「< 1 px」量级 — **本清单可判定（读数）**

**操作**：主屏雷达卡，读那行「平移量 X px@7 …」。

**判据**：`X` 是个**小于 1 的小数**（理论值 0.3~0.9 量级，随城市变）。
-若看到「平移量 ≥ 1 px」→ 与实测结论矛盾，需查 `CoordinateTransform.pixelShiftProbe`
  （`Core/Logic/CoordinateTransform.swift:555`）的输入，尤其 `contentScaleFactor`
  是否被当成了 1（`RadarMapCard.swift:554` 传的是 `UIScreen.main.scale`）。
- 若显示「未平移」→ 当前是 `.off`（见 3.3），读数分支不显示数字，属预期。

**读代码确认**：`isVisuallyDetectable` 的判据是 `>= 1.0` 设备像素
（`CoordinateTransform.swift:440`），实测结论是**全中国境内 552 瓦片0 个达到 1px**。

---

### 3.5 四态降级各自的**表现** — **本清单可判定（除回波态外均需构造）**

四态与判定入口 `Core/Models/RadarFrame.swift:269` `RadarAvailability.resolve`。

| 态 | 触发条件 | 顶部结论句（唯一真源 `:189`） | 时间轴 scrubber |
|---|---|---|---|
| `.radar` | 有帧 + 境内 | 「雷达回波 · RainViewer 全球合成」 | **可用** |
| `.forecast(.domesticHourly)` | 境内但 `past` 为空 | 「本区域暂无实时回波 · 显示逐时降水概率」 | **禁用** |
| `.forecast(.overseasTwoHour)` | **境外**城市 | 「境外区域 · 显示未来 2 小时降水概率条」 | **禁用** |
| `.radarUnavailable(.fetchFailed)` | 取数失败 | 「雷达图加载失败 · 下方为模型预报」 | **禁用** |
| `.radarUnavailable(.noFrames)` / `.noEchoCoverage` | 无帧 / 覆盖盲区 | 「本区域暂无实时回波 · 下方为模型概率」 | **禁用** |

**怎么分别构造 + 判据**：

**① 境外态（最容易、最确定，建议第一个做）**
- **操作**：设置里把选中城市切到境外城市（如东京、首尔；或在 CityList 里搜一个境外城市）。
- **判据**：顶部结论句 == 「境外区域 · 显示未来 2 小时降水概率条」，
  **且地图上不叠回波层**（只有底图），**且没有可拖动的 scrubber**。
- **若失败，先查**：`RadarCardModel.isOverseas`（`RadarCardModel.swift:138`）复用
  `CoordinateTransform.isInsideChinaBox`——若境外城市被判成境内，看这个边界判定。

**② 境内无回波态（最常见，就是默认看到的那态）**
- **操作**：选一个当前**没有降水回波**的境内城市，等它加载完。
- **判据**：顶部句是「本区域暂无实时回波 · 显示逐时降水概率」或
  「本区域暂无实时回波 · 下方为模型概率」；
  **地图仍有底图**（不是空白）；**下方有逐时概率内容**（这是「仍给出可看的替代内容」的要求）。

**③ 取数失败态（飞行模式，最可靠）**
- **操作**：开飞行模式 → 下拉主屏刷新 → 观察雷达卡，等 12 秒以上。
- **判据**：顶部句 == 「雷达图加载失败 · 下方为模型预报」；
  **地图有底图**；**没有**无限转圈（超时后必须显示底图 + 超时文案，
  `RadarMapCard.swift:666` → 「雷达加载超时 · 已显示底图，下方为模型概率」）。
- **判据补充**：飞行模式下若**一直**转圈超过 20 秒 → **失败**（超时兜底没生效）。
- **若失败，先查**：`RadarCardModel.hasTimedOut`（`:73`）与 `loadTimeout`（`:62`，12 秒）。

**④ 真回波态（需要特定条件，见 5.1）**
- 判据：顶部句 == 「雷达回波 · RainViewer 全球合成」，且**时间轴可拖动**，
  拖动时左上角「实况 / 回放中」会切换，底部显示「10 分钟粒度 · 共 N 帧」。

---

### 3.6 归属署名不可删改 — **本清单可判定**

**判据**：雷达卡左下角**逐字**显示「Weather data by RainViewer」，且「RainViewer」是**可点链接**。
- 若署名缺失或文案被改成「数据来源」之类 ⇒ **失败**（RainViewer 许可的硬要求）。

---

### 3.7 切城市不串号 — **本清单可判定**

**操作**：选一个有回波的境内城市，等地图出图 → **立刻**切到另一个城市。

**判据**：新城市的卡上**不出现**上一个城市的回波帧；切城后回波要么变成新城的、要么退回降级态，
**但绝不是旧城的图**。

**若失败，先查**：`RadarCardModel.load` 里的切城守卫（`:190`、`:196`、`:202`
三处 `guard currentCityID == cityID`），以及 `currentCityID` 声明（`:214`）。

---

### 3.8 瓦片层级被钳制在 4–7（z8 不请求）— **本清单可判定（间接）**

**背景**：z8 起 RainViewer **恒返回占位图**，用户会看到灰块。

**操作**：把地图**放到最大**，反复双指放大，直到系统不再继续放大。

**判据**：屏幕上**不出现灰色棋盘格 / 灰色占位瓦片**。若出现 ⇒ 失败。

**若失败，先查**：`RadarTileOverlay.correctedTileCoordinates`（`RadarMapCard.swift:138`）
的 `RadarTileZoomRange.clamp`，以及 `RainViewerService.swift` 里
`RadarTileZoomRange.minimum = 4` / `maximum = 7`（`:55`/`:58`）。
占位图拒收逻辑在 `RadarTileCache`（失败时传 nil，绝不让灰图上屏，见 `RadarMapCard.swift:184`）。

---

## 4. 预警 / 版本 / 诊断（7 条）

### 4.1 设置页能看到版本 + 构建号 — **本清单可判定（装包后必做）**

**为什么必须做**：侧载安装时系统不刷新图标缓存，桌面图标**无法**告诉你装的是新包还是旧包。
只显示版本号（如 `0.1.0`）每次构建看起来都一样 → 会导致「改了没生效」的误判。

**操作**：主屏 → 设置 → 滚到底部「关于」Section。

**判据**：显示成**两段**格式 `版本号 (构建号)`，例如 `0.1.0 (123)`。
- 若只显示 `0.1.0`、**括号里没有构建号** ⇒ **失败**。
- 若显示 `--` ⇒ 失败（Info.plist 键读不到）。

**若失败，先查**：`ZhishengWeather/SettingsView.swift:767` `appVersion`
（读 `CFBundleShortVersionString` + `CFBundleVersion`，`:768`/`:769`），
渲染位置 `:504`。

**操作（连带判定：本轮的新功能装没装上）**：把读到的构建号与你 push 的那次 CI
run 号对照。若对得上，说明你测的就是新包。

---

### 4.2 NMC 预警列表能否显示 — **需要特定条件（取决于当天有无预警）**

**操作**：下拉主屏，找「官方预警」卡。

**判据**：
- **若当天该城市无预警** ⇒ 整卡**不显示**（`.none` 态整卡隐藏，`OfficialWarningCard.swift:87`）。
  这是**正确行为**，不是失败。
- **若有预警** ⇒ 卡上出现预警条目，最多 **3 条**，底部若有剩余显示「还有 N 条」；
  右上角徽标显示**最高档颜色名**（如「红色预警」）；条目行有 ▼ 箭头。
- **任何情况下，这张卡都不该显示成空白或"出错了"。**

**若失败，先查**：`OfficialWarningState.resolve`（`Core/Models/OfficialWarning.swift:182`），
排序在 `sorted`（`:197` 调用）。

---

### 4.3 防御指南正文能否展开 — **需要特定条件（必须有预警）**

**操作**：有预警时，点某一条预警行（整行可点）。

**判据**：
1. 行**展开**（▼箭头由 -90° 转到 0°，`OfficialWarningCard.swift:231`）。
2. 展开后出现「防御指南」小标题 + **一段中文正文**（`:270`/`:274`）。
3. 正文**逐字**是官方原文，**无HTML 标签、无`&xxx;` 实体、无 `[object Object]` 之类脏东西**。
4. 正文区**不撑爆卡片**（有 120pt 封顶 + 可滚动，`:287`）。

**若失败，先查**：`defenseGuideBody`（`OfficialWarningCard.swift:259`）。
若显示的是「暂无防御指南正文。」→ 这是**如实的缺失**，说明**上游没给**正文
（不是渲染 bug）；排查方向是 `OfficialWarningEnrichment`（`Core/Logic/`）的补源是否成功。

---

### 4.4 无正文时是否**如实**说明（而非编内容）— **需要特定条件（需某条预警恰好无正文）**

**判据**：展开一条**无正文**的预警 → 显示「暂无防御指南正文。」
（`:264`），且**绝不**出现任何编造的建议文本。

**说明**：这条**很难在真机上凑到**（实测 5/5 条都有正文，长度 137~154 字符）。
**归入「需要特定条件」，且不要为凑它而等天气。**

**若失败，先查**：同上；这条的正确结果是「如实为空」，任何非空内容都是 bug。

---

### 4.5 预警取不到数时是否显式说明（而非静默消失）— **本清单可判定（飞行模式）**

**这是预警卡最重要的一条**：灾害天气里把「取不到」画成「无预警」是**内容错误**。

**操作**：开飞行模式 → 下拉主屏刷新 → 找预警卡。

**判据**：
- 显示「预警数据获取失败」（`:299`），**或**「预警数据已过期」（`:303`）。
- **绝不允许**：整卡消失、或显示成一片平静（那正是这个缺陷）。

**若失败，先查**：`staleBody`（`OfficialWarningCard.swift:295`）与
`OfficialWarningState.StaleReason`（`Core/Models/OfficialWarning.swift:151`）。

---

### 4.6 「小组件自查」区能读到共享容器的真实状态 — **本清单可判定**

**操作**：设置 → 找「小组件自查」Section。

**判据**：
- 「共享容器」右侧显示 **「不可用」**（红字）。
  侧载产物上这**就是正确结果** —— App Group entitlement 不生效，容器恒不可用
  （`AppGroupStore.swift:200`）。**若显示「可用」，反而要警惕。**
- 下面那行说明文字是「本安装的共享容器不可用（未签名 / 重签侧载下 entitlements 不生效）…请长按桌面小组件 → 编辑小组件 → 城市，手动选一次…」
  （`SettingsView.swift:755` `widgetManualCityHint`）。
  - **判据**：这句话里**必须**出现「编辑小组件 → 城市」这条出路。
  - **反判据**：若出现「请在主 App 中打开一次天气」这类提示 ⇒ **失败**
    （那是**已知被判掉**的历史文案，见 `Core/Logic/WidgetCopy.swift:22-26`：
    在侧载渠道上「去开主 App」不可能改变状态，属无效提示）。

---

### 4.7 「重载小组件时间线」是否留下可读记录 — **本清单可判定**

**操作**：设置 →「小组件自查」→ 点「重载小组件时间线」→ **退出设置页再进**。

**判据**：该区出现一条诊断记录，含**「已请求重载 HH:mm:ss」**这样一行带时刻的文字，
且**退出再进仍然在**（持久化，不是闪一下就没）。

**若失败，先查**：`requestWidgetTimelineReload`（`SettingsView.swift:567`）
与 `AppDiagnosticsStore.record`（`ZhishengWeather/AppDiagnosticsStore.swift:170`，
写盘失败只print 不上抛）。

---

## 5. 其他只能真机验的点（4 条）

### 5.1 强回波时刻 — **需要特定条件**

**判据**：当天该城市有**明显降水回波**时，雷达卡顶部句 == 「雷达回波 · RainViewer 全球合成」，
且时间轴 scrubber **可拖动**，底部显示「10 分钟粒度 · 共 N 帧」，拖动时左上角「实况 / 回放中」切换。

**为什么必须等条件**：3.5 的 `.radar` 态、以及 3.2 替代办法 A（量纠偏偏移）**都依赖它**。
没有强回波，这两条就只能记为「未验」，**不要**用「看到了回波」之外的东西替代。

### 5.2 「数据延迟 N 分钟」提示 — **本清单可判定（与 5.1 同条件）**

**判据**：回波时间轴可用时，若最新帧距今 > 20 分钟，卡下方出现
「数据延迟 N 分钟 · 回波每 10 分钟更新」（`RadarMapCard.swift:720`）。
N 应 ≤ 20（超过则不显示，这是阈值设计）。

**若失败，先查**：`RadarTimeline.ageMinutes(now:)` 与 `TimelineView(.everyMinute)` 注入的 `context.date`。

### 5.3 「当前位置」被选中后是否真取到点 — **需要特定条件，且本清单判不了**

**操作**：小组件配置选「当前位置」，在App 内授权定位，等刷新。

**判据**：标题不再是 `—`，且能显示温度。
- 若显示「定位未授权」（`WidgetCopy.swift:109`）⇒ 授权没拿到。
- 若显示「位置暂时不可用」（`:111`）⇒ 已授权但 Apple 只在组件可见后一小段时间内提供定位（`WidgetCopy.swift:49-51` 注释），
  提示应为「可改选具体城市试试」（`:169`）。

**⚠️ 诚实标注**：Apple 对小组件定位的提供时机没有公开承诺，
**这条的失败无法区分「代码错」与「系统没给定位」**。判失败时请记录
是「提示说定位未授权」还是「位置暂时不可用」，前者更可能是真问题。

### 5.4 备用图标 — **需要特定条件（需确认本安装保留了备用图标声明）**

**操作**：设置 →「应用图标」。

**判据**：Picker 三档可选（磷光 / 清冷翡翠 / 终端雨字）**且能真的切换成功**。
若整个 Picker 置灰 → 看下方红字说明（`:199-203`），这是 LaunchServices 拒绝（-54）时的**如实降级**，
不算 bug；侧载重签裁plist 时声明常被去掉。

**若失败，先查**：`AppIconSwitcher.supportsAlternateIcons()`
与设置页那行 `iconSwitcher.diagnosticsSummary()`（`:196`）——**读的是设备事实，不是构建产物的假设**。

---

## 6. 汇总与可行性分类

共 **29 条**：可判定 **19** / 需要特定条件 **7** / 真机也判不了**3**。

| 分类 | 条目 |
|---|---|
| **本清单可判定** | 2.1、2.2、2.3、2.4、2.5、2.6（列表呈现部分）、3.1、3.3（弱判据）、3.4、3.5（②③ 境外/失败/无回波）、3.6、3.7、3.8、4.1、4.5、4.6、4.7 |
| **需要特定条件** | 3.5①中的强回波态、3.2 替代办法 A（需强回波才能量偏移）、4.2、4.3、4.4、5.1、5.2、5.3、5.4 |
| **真机也判不了，必须换手段** | **3.2（纠偏方向）**、**3.3（平移开关差别）**、**3.4 的「差异是否可见」部分** |

### 6.1 「真机也判不了」的三条，建议怎么处置

| 项 | 为什么判不了 | 建议的换手段 |
|---|---|---|
| 3.2 纠偏方向 | z4–z7 上纠偏是恒等变换（切档不改变任何瓦片请求）**叠加**真实偏移 < 1 设备像素（@2x 最大 0.93px，肉眼不可辨） | **接受「方向未验证」这个状态**，并保留 UI 上现有那句「纠偏方向未验证」。若非要定：① 放大截图量边界像素距离（需强回波，属有条件）；② 等 RainViewer 支持 z≥15（半格 ≤611m < 最大偏移 663m，纠偏才不再是恒等，见 `CoordinateTransform.swift:196`）；③ **不要**用切档。 |
| 3.3 平移开关差别 | 当前构建**没有 UI 入口**：`RadarPixelShiftStore.set` 全仓无调用点 | 要验必须先加设置页 Picker（改 Swift 代码）。在那之前，本清单只能验「读取通路+ 文案诚实」这个弱判据。 |
| 3.4 差异可见性 | 即使能开关，0.3~0.9px 的平移在屏幕上就是看不出 | 接受。若要证明机制生效，可考虑**放大平移量做诊断模式**（如 ×50），但那是新功能，不是验收。 |

---

## 7. 失败时的第一排查点（速查表）

| 现象 | 起点（文件:行号） |
|---|---|
| CI step 7 编译失败 | `Core/Networking/WeatherCnAlarmResponse.swift:126` `Row.init(from:)` |
| 小组件标题是 `—` / 配置被改写 | `Core/Logic/WidgetCityIntent.swift:314` `init()`；`:247` 的 `.followApp` 兜底 |
| 小组件标题对但 `--°` | `Core/Logic/WidgetDataResolver.swift:121` L1 分支；`WidgetWeatherService` 8s 超时 |
| Large 空态出现多句「暂无」 | `ZhishengWeatherWidget/LargeWeatherView.swift:74` `hasPayload` 门控 |
| 出现「请在主 App 中打开」这类无效提示 | `Core/Logic/WidgetCopy.swift:22-26`（已判掉的历史文案） |
| 雷达一直转圈 | `ZhishengWeather/RadarCardModel.swift:73` `hasTimedOut`；`:62` `loadTimeout = 12` |
| 雷达某态是空白地图 | `ZhishengWeather/RadarMapCard.swift:655` `degradedOverlayText`（`.radarUnavailable` 不得返回 nil） |
| 切城市出旧城回波 | `ZhishengWeather/RadarCardModel.swift:190/196/202` 三处切城守卫 |
| 灰块占位图上屏 | `ZhishengWeather/RadarMapCard.swift:138` `clamp`；`RainViewerService.swift:55/58` |
| 预警取不到却显示「无预警」 | `ZhishengWeather/OfficialWarningCard.swift:295` `staleBody` |
| 防御指南显示脏东西 | `ZhishengWeather/OfficialWarningCard.swift:259` `defenseGuideBody`；上游补源 `Core/Logic/OfficialWarningEnrichment.swift` |
| 版本只显示 `0.1.0` 无构建号 | `ZhishengWeather/SettingsView.swift:767` `appVersion` |
| 共享容器显示「可用」（侧载下可疑） | `Core/Storage/AppGroupStore.swift:200` `isSharedContainerAvailable` |

---

## 8. 明确区分：读代码确认 / 推测 / 无法确定

### 8.1 读代码确认（有 `文件:行号`，可复核）

- 平移档位无 UI 入口：`RadarPixelShiftStore.set` 全仓无调用点；`SettingsView.swift:274-297` 无平移 Picker。
- 纠偏在 z4–z7 恒等：`CoordinateTransform.swift:810`、`:822`；`RadarTileZoomRange` = 4...7（`RainViewerService.swift:55/58`）。
- 内置城市 34 个：`WidgetBuiltInCities.swift:56`；断言在 `WidgetBuiltInCitiesTests.swift:19`。
- Large 空态门控：`LargeWeatherView.swift:74`。
- 小组件刷新策略 45 分钟：`WeatherProvider.swift:104`。
- 版本号两段格式：`SettingsView.swift:767-773`。
- HEAD 未 push、CI run 数 0、最近一次 CI 失败于 step 7：`git` 与 GitHub API 查询结果。

### 8.2 推测（**未在真机验过**，当作假设对待）

- 「0.45px / 0.51px（@1x）、0.70 / 0.93px（@2x）」这几个具体数值来自
  `d715851` 的提交与代码注释，**本清单未独立复算**。
- 「552 瓦片 0 个 ≥ 1px」同属代码注释里的实测结论，未独立复算。
- 防御指南正文「137~154 字符、换行 0 个、无 HTML」来自 `OfficialWarningCard.swift:41-47`
  的实测记录（2026-10-06 抓取），本清单未重新抓取上游验证。

### 8.3 无法确定（本清单明确判不了的）

1. **MapKit 是否对 `MKTileOverlay` 自动施加 GCJ-02 偏移** —— 即 3.2 的纠偏方向。
   代码里 `CoordinateTransform.defaultMode`（`:202`）的三条依据中，
   依据 2「失效方向不对称」已被本轮推翻，依据 1（Apple DTS 说 annotation 也不纠偏）
   只是**旁证**，不是对 tile overlay 的直接断言。**此项在本清单里没有结论。**
2. **真机上 AppIntents 重签后配置是否真送达 widget 进程** —— 代码里没有任何可观测点能回答。
   2.3 / 2.5 只能观察「读回来是什么」，无法区分「系统没存」与「存了但没送达」。
3. **系统是否真调用过 `timeline(for:)`** —— ✅ **本轮已解决**，见第 10 节。
   此前「无日志、无埋点、无计数器」；现每次调用必成对产出 `ENTER` / `EXIT` 两行
   （`Core/Logic/WidgetDiagnostics.swift` 的 `WidgetTrace`），
   缺哪一行都能直接判出问题层级。
4. **小组件定位失败是代码问题还是 Apple 不给定位** —— 见 5.3 的诚实标注。

---

## 10. 小组件「没数据」的三态判读（**本节是 2.3 的根因定位工具**）

> 为什么有这一节：2.3 只能看「屏幕上显示什么」，**分不清问题在哪一层**。
> 本节给出的是**可执行的判读表** —— 把三种可能区分开：
> **系统没调我们** / **调了但取数失败** / **取到了但渲染不出来**。

### 10.1 前置：这些日志是本轮（`dce9875` 之后）才有的

⚠️ 手上装的包若 `head_sha` 早于引入 `WidgetTrace` 的那一版，
**Console 里会一条日志都没有** —— 那不代表小组件正常，只代表**包太老**。
先用 4.1 核对构建号。

### 10.2 怎么抓日志（两条路，各管一半）

**路 A — 连 Mac 抓（管「系统调没调timeline / 取数成没成功」）**

手机与 Mac 连线后，在 Mac 终端：

```bash
# 实时跟（推荐：先跑命令，再去手机上点小组件的 ⟳ 强制刷新）
log stream --predicate 'subsystem == "com.zhisheng.weather.core" AND category == "widget"' --level info

# 或者：抓一段历史（手机没连着、或想看刚才那次）
log collect --last 30m --output /tmp/zs.log
log show /tmp/zs.log --predicate 'subsystem == "com.zhisheng.weather.core" AND category == "widget"'
```

- Console.app 里等价操作：搜 `category == "widget"`（或 subsystem `com.zhisheng.weather.core`）。
- ⚠️ `--level info` 不能省：`ENTER/EXIT` 打的是 `notice` 级，
  而 `log stream` 默认**只显示 `default` 及以上**，漏掉这个参数会一条都看不到
  （这是最容易踩空的一步 —— 看到「空日志」先确认自己加了 `--level info`）。

**路 B — 不连 Mac，在 App 内看（管「系统认不认这个实例」）**

设置 →「小组件自查」→点**「查询系统登记的小组件」**。

这一条查的是 `WidgetCenter.currentConfigurations()`，即**系统认为存在几个实例、
各自什么尺寸**（设备事实，不是我们对自己代码的假设）。

⚠️ **两路管的事不一样，不能互相替代**：
小组件进程的执行轨迹**写不进 App 的诊断存储** ——
扩展的 `UserDefaults.standard` 落在扩展自己的沙盒里，主 App 读不到
（这是**沙盒边界本身**，与 App Group 是否可用无关）。
所以「timeline 到底跑没跑」**只能**靠路A。

### 10.3 日志长什么样（真实格式，逐字段）

一次成功的 timeline 会打出这几行（`#N` 是本次调用的关联序号）：

```
#7 timeline ENTER family=small preview=0 mode=fixed(30.28,120.16)
#7 CITY outcome=resolved cityID=30.28,120.16
#7 FETCH start endpoint=https://api.open-meteo.com/v1/forecast?latitude=30.28&longitude=120.16&current&hourly&daily&minutely_15&forecast_minutely_15&wind_speed_unit&forecast_days&past_days&timezone&timeformat
#7 FETCH http=200 bytes=48213
#7 FETCH end result=ok
#7 timeline EXIT status=available source=selfFetched empty=- hasPayload=1
```

**只有 6 行**，且每个 timeline 恒定 6 行（`FETCH` 三行只在真的发请求时出现）。
系统对每实例的刷新预算是每小时数次量级，故不构成刷屏。

### 10.4 判读表（**这是本节的核心**）

**第一刀：有没有 `timeline ENTER`？**

| 观察 | 结论 | 下一步 |
|---|---|---|
| **完全没有 `timeline ENTER`** | ⚠️ **系统根本没调我们的 timeline** | **不是我们取数的问题**。见 10.5 |
| 只有 `placeholder ENTER`，没有 `timeline ENTER` | 系统只在渲染画廊/占位，从未真正拉时间线 | 同上，10.5 |
| 有 `timeline ENTER`，且 `EXIT` 里 `hasPayload=1` | **取数成功了** → 若屏幕仍空，问题在**渲染层** | 见 10.6 |

**第二刀：`ENTER` 行的 `mode=`（配置有没有送达）**

| `mode=` | 含义 | 下一步 |
|---|---|---|
| `fixed(30.28,120.16)` | ✅ 用户选的城市**已送达** | 配置没问题，看 `CITY` 行 |
| `followApp` | 配置被读回成「跟随 App」= **用户的具体城市没送达** | `Core/Logic/WidgetCityIntent.swift:314` `init()`；`:247` 的 `.followApp` 兜底 |
| `currentLocation` | 配的是「当前位置」 | 看 `CITY` 行的 `outcome` |
| —（`placeholder` 行恒为 `none`） | 占位渲染本来就没有配置 | 正常 |

**第三刀：`CITY` + `FETCH` + `EXIT` 的组合**

| `CITY outcome` | `FETCH` | `EXIT empty` | 结论 |
|---|---|---|---|
| `needsConfig` | 无 | `noCity` | **无城市**（容器空且配置无效）→ 按提示手动选城市 |
| `resolved` | `http=200` + `result=ok` | `-`（`hasPayload=1`） | ✅ **数据到手**。屏幕仍空 → **渲染层**问题 |
| `resolved` | `http=4xx` | `fetchFailed` | 上游拒绝（401/403 = 凭据/配额，429 = 限流） |
| `resolved` | `http=5xx` | `fetchFailed` | 上游故障，稍后重试 |
| `resolved` | `http=200 bytes=0` | `cityHasNoData` | 上游返回空体 → **换城市** |
| `resolved` | `result=decodeFail(path=…)` | `fetchFailed` | **字段路径变了**（上游改结构），照 path 定位 |
| `resolved` | `result=timeout` | `fetchFailed` | 8s 内没拿到（`WidgetWeatherService.requestTimeout`） |
| `resolved` | `result=network` | `fetchFailed` | 传输层失败（飞行模式/弱网） |
| `locNotAuthorized` | 无 | `locNotAuthorized` | 「当前位置」未获授权 → 去设置里授权 |
| `locUnavailable` | 无 | `locUnavailable` | 已授权但本轮没点（Apple 常态）→ 改选具体城市 |

### 10.5 ⭐ 「日志为空」的确切含义（用户最该先看这条）

**若 `log stream` 开着、命令行加了 `--level info`、手机连着，
点过小组件的 ⟳ 强制刷新，而日志里一条 `category == "widget"` 都没有 ——
那么结论只有一个：**

> **系统从来没有调用过我们的 `timeline(for:)`。**
> 问题**不在**我们的取数代码上（取数代码压根没被执行过）。
> 排查方向是**系统侧 / AppIntents 侧**，不是本仓库的 Swift 逻辑。

具体可能（按可能性排序，**均未在真机验证，属推测**）：

| 可能 | 怎么进一步确认 |
|---|---|
| 系统把该实例的刷新**预算耗尽**了（预算按 widget kind 计） | 隔很久（如 1 小时）后再点 ⟳，看是否突然出现日志 |
| 侧载重签后 AppIntents 的配置**没能送达**扩展进程 | 走 2.2 / 2.5：编辑界面里能否看到并保存城市 |
| 该实例处于**智能堆叠**且当时不可见 | 把小组件拖回桌面主屏，再点 ⟳ |
| 系统认为该实例不需要更新（内容未过期） | 强制刷新后仍无日志，等过45 分钟再看 |

⚠️ **这一档不要改 Swift 代码去「试」。** 本项目的既有教训是
「注释说实测但没实测」（见 8.2）—— 日志为空时能确定的只有
「系统没调我们」这一件事，**具体是哪一种原因，日志答不了**，
需要社区侧或更高层的信息（如设备 Console 的完整 WidgetKit 报错）。

### 10.6 「数据到手但屏幕空」的排查

若 `EXIT hasPayload=1`（数据确实到手）而屏幕仍是空态，
则问题在**视图层**，按此顺序查：

1. `ZhishengWeatherWidget/WeatherEntry.swift:55` `payload` 转发 —— 确认 entry 带的是真载荷。
2. `ZhishengWeatherWidget/LargeWeatherView.swift:74` 的 `hasPayload` 门控 —— 空态整段不渲染。
3. `Core/Logic/WidgetCopy.swift` 的 `cityText` / `conditionText` —— 文案是否与实际状态一致。

### 10.7 日志里绝不含凭据（可以放心把日志发出来）

用户可能想把日志贴给社区，故这里明确承诺：**日志里不可能出现凭据**。

保证方式是**白名单式脱敏**（`WidgetTrace.redactedEndpoint`），
不是「记得别打 key」这种靠自觉的做法：

- URL 的 **query值只有名字在白名单里时才输出**，白名单当前**只有
  `latitude` / `longitude` 两项**（`WidgetDiagnostics.swift` 的
  `diagnosticQueryKeys`，单测钉死）；
- 其余参数（`current` / `hourly` / `apikey` / 任何未来新增的）
  **一律只输出参数名，值无条件丢弃**；
- 错误只打**自定义 token**（如 `timeout` / `badStatus(429)`），
  **绝不打 `localizedDescription`**（`URLError` 的描述可能回显请求 URL）；
- 响应**只打状态码与字节数，不打 body**。

单测见 `ZhishengWeatherTests/WidgetTraceRedactionTests.swift`，
其中 `testWhitelistIsExactlyCoordinates` 会在有人往白名单里加东西时**强制变红**，
逼他确认那到底算不算凭据。

⇒ **日志可以直接贴到 issue / 社区**，无需打码。

### 10.8 读代码确认 / 推测 / 无法确定

**读代码确认**（有 `文件:行号`）：

- 本仓 widget 时间线**此前无任何日志**：`ZhishengWeatherWidget/WeatherProvider.swift`
  在本轮之前没有 `print` / `os_log`；`DEVICE-VERIFICATION.md` §8.3 第 3 条原文
  「无日志、无埋点、无计数器」可复核。
- `Core/` 被**两个 target 同时编译**（`project.yml:84` 主 App、`:124` Widget），
  故 `Core/Logic/WidgetDiagnostics.swift` 里的 `WidgetTrace` 对小组件进程可用。
- `AppDiagnosticsStore` 在 `ZhishengWeather/`（`project.yml:83`，**仅主App target**），
  故小组件进程**用不到**它 —— 这是「日志只能走 os_log」的**结构性**原因。
- 小组件请求地址由 `Core/Networking/OpenMeteoEndpoint.swift:161` 拼装，
  **当前不带任何 key**（参数只有经纬度与字段列表）。
- `FETCH http=` 那行打在 `Core/Networking/WeatherService.swift` 的
  `(200..<300).contains(http.statusCode)` 判定**之前** ——
  所以**非 2xx 也能看到状态码**，这是判读表里 4xx/5xx 分得开的前提。

**推测**（**未在真机验证**，当作假设对待）：

- 10.5 表里「系统没调我们」的四条原因及排序，**均未在真机复现过**。
  它们是「按WidgetKit 公开行为 + 社区常见现象」列出的候选，不是结论。
- 「`placeholder ENTER` 只出现而不出现 `timeline`」的触发条件
  （画廊预览 vs 桌面首屏渲染的区分）**未在真机观察过**，
  这条判读是**基于代码结构**（`placeholder(in:)` 与 `timeline(for:in:)` 是两个入口）
  推出的可用信号。

**无法确定**：

1. `os_log` 在**发布版（Release）**下是否仍全部保留 ——
   本项目 CI 出的 IPA 是 `Release` 归档（`project.yml` 的 `archive: config: Release`），
   `Logger` 的日志**不依赖调试器**，但系统对 `notice` 级日志有速率限制，
   高频调用下**是否被节流丢弃未实测**。若 10.3 的行偶尔缺失，先怀疑这一点，
   别急着判「系统没调」。
2. AppIntents 配置在侧载重签后**是否真送达**扩展进程 ——
   本节只能看到「送达与否」（`mode=`），**看不到送达机制为何失败**。
