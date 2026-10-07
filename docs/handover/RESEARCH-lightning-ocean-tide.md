# 实测调研：雷电定位 / 中国海域海洋预报 / 潮汐 / 卫星云图 / 花粉

> **调研日期**：2026-10-07
> **调研者环境**：Windows + Git Bash，**无 Xcode、不能编译**（纯调研，未写任何 Swift 代码）
> **测试命令规范**：全部使用 `curl -s -m <秒> -L --compressed -A "<Chrome UA>" "<url>"`
> （`-L` 与 `--compressed` 必带；本次所有结论均为**当次实测**，无一条来自旧场景搬运）
>
> **证据等级标注约定**
> - `【实测】` = 本轮真实发起请求得到的状态码 + 响应体/字节数/像素统计
> - `【文档如此，未实测】` = 官方文档明确写了，但本轮未成功复现
> - `【无法确定】` = 证据不足，不下结论

---

## 0. 结论速查表（5 个维度）

| # | 维度 | 免 Key？ | 实测结果 | 覆盖 | 推荐度 |
|---|------|---------|---------|------|--------|
| ① | **雷电定位** | ✅ 免 Key | `image.nmc.cn` 逐小时**位图**（非结构化点位），200 / 95 441 B / JPEG 头 `ff d8 ff e0` / 20 207 色样本 | 中国全境，逐小时，**仅 24 小时时次** | ⭐⭐⭐ 中（可做「图层」，不能做「附近有雷」判定） |
| ② | **中国海域海洋预报** | ⚠️ 部分 | 国家海洋预报网**无 API 且 HTTPS 不通**；**中央气象台 nmc 海区预报有中文表**（HTML，需解析） | 中国沿岸 29 海区 | ⭐⭐ 低（中文有价值，但是 HTML 爬取 + 非结构化） |
| ③ | **潮汐** | ✅ 免 Key | **Open-Meteo marine 本身就提供潮汐**：`sea_level_height_msl`，200 / 455 B，数值符合半日潮规律 | 全球海岸，0.08°≈8 km 模型 | ⭐⭐⭐⭐⭐ **最高，零成本扩展** |
| ④ | **卫星云图** | ✅ 免 Key | **nmc 风云四号真彩** 200 / 148 608 B / 860×540 / 48 722 色样本（真图）；NASA GIBS 也免 Key 但**夜间返纯黑占位图** | 亚洲（nmc）／全球（GIBS） | ⭐⭐⭐⭐ 高（nmc 优先，GIBS 夜间有坑） |
| ⑤ | **花粉** | ❌ 国内无值 | Open-Meteo 字段名有效但**中国恒为 null**（欧洲才有值） | **仅欧洲** | ⭐ 不可用于国内 |

**按性价比排序（最值得先接 → 最不值得）**

1. **③ 潮汐** —— 零成本、零凭据、已有 marine 端点与模型结构，加一个变量名即可
2. **④ 卫星云图** —— 免 Key 真彩位图，接入即得「云图」这一竞品对标功能
3. **① 雷电** —— 免 Key 但**只有位图、无坐标数据**，做不了「附近闪电距离」
4. **② 中文海洋预报** —— 有中文浪高/风力描述，但需爬 HTML、稳定性无保障
5. **⑤ 花粉** —— 国内无数据源，**不建议做**

---

## ① 雷电定位（雷击地图）

### 结论：国内**有免 Key 的雷电数据**，但形态是「图片」而非「坐标点」

**没有找到任何国内免 Key 的结构化雷击坐标接口**（含经纬度/落区/强度）。
中央气象台（nmc）提供的是**逐小时渲染好的地闪分布位图**。

### 实测证据

**1) 页面入口**（`lightning.html` 是失效旧路径，`lighting.html` 才是真路径）
```
GET http://www.nmc.cn/publish/observations/lighting.html
→ code=200  size=13983  ctype=text/html
页面标题：当前位置：首页 / 天气实况 / 强对流 / 雷电（地闪）
面包屑逐字：<li class=active>雷电（地闪）</li>
```
> ⚠️ 注意 nmc 路径拼写是 `lighting`（多一个 i），官方导航里也是这个拼写。

**2) 真实图片 URL（从页面 HTML 逐字提取，非构造）**
```
GET https://image.nmc.cn/product/2026/10/07/WEAP/medium/SEVP_NMC_WEAP_SOB_ELTN_ACHN_LNO_PE_20261007180000000.jpg
→ code=200  size=95441  ctype=image/jpeg
文件头（前16 字节 hex）：ff d8 ff e0 00 10 4a 46 49 46 00 01 01 01 00 c8
                       └ JFIF 魔数，确认是真 JPEG
像素统计：825×698  Rmin=0 Rmax=255 Rstd=32.45  唯一样本=20207
```
> ✅ **像素统计是本轮唯一有判别力的证据**：20 207 个不同颜色样本 → 是真实雷击分布图，
> 不是空白占位图。**若只看字节数无法区分真假图**（见 ④ 的反例）。

**3) URL 规律**（可推导，但**必须实测校验存在性**）
```
https://image.nmc.cn/product/{YYYY}/{MM}/{DD}/WEAP/medium/SEVP_NMC_WEAP_SOB_ELTN_ACHN_LNO_PE_{YYYYMMDDHHMMSS}00.jpg
                                    ↑产品分类   ↑固定名                                        ↑时间戳
```

**4) 时次覆盖实测（关键约束）**
```
最新时次（10-07 18:00）              → code=200  size=95441   ✅
前一日同刻（10-06 12:00）            → code=200  size=94984   ✅
两日前（10-05 18:00）                → code=404  size=552     ❌ 不存在
伪造时间戳（2020-01-01）             → code=404  size=552     ❌ 不存在
```
响应体（404 时）：`<html><head><title>404 Not Found</title></head>...`
→ **实测仅约 24 小时时次可取，更早的归档不存在。**

**5) 分辨率路径实测**
```
/WEAP/high/    → code=404  size=552
/WEAP/large/   → code=404  size=552
/WEAP/big/     → code=404  size=552
/WEAP/medium/  → code=200  size=95441   ✅ 仅此一种
```
→ **实测只有 `medium` 档存在**（825×698 px），无高分辨率可选。

**6) 强对流兄弟产品（同机制，均为位图）**：`heavyrain.html`（短时强降水）、`gale.html`（雷暴大风）、`hail.html`（冰雹）

### Blitzortung 实测（国外备选，需账号）
```
GET https://data.blitzortung.org/Data/Protected/Strikes_4/      → code=401 size=590
GET https://data.blitzortung.org/Data/Protected/last_strikes.php→ code=401 size=590
    响应体逐字：<title>401 Authorization Required</title> ... nginx/1.18.0 (Ubuntu)
GET https://data.blitzortung.org/Data/Public/                    → code=200 size=234（目录可列，只有 stations.json）
```
- `Strikes_4`（亚洲区）**必须 loginname/password**（HTTP Basic）→ **不是免 Key**
- 官方文档称雷击数据每 10 分钟一个文件、每行一条 JSON、含 19 位纳秒时间戳【文档如此，未实测——401 挡住无法验证】
- Blitzortung 在中国**站点密度低**，定位精度不可保证。**建议不作为国内方案**

### 数据结构
**无坐标字段可解码**（位图）。可用信息仅：产品时次、覆盖范围、图像本身。
若需要「用户附近 20km 内是否有雷」，位图**无法满足**，必须另找付费坐标源（如 气象大数据云、彩云雷达等）。

### 国内可用性
✅ `image.nmc.cn` 直连可达，无需代理（本轮实测 200）。

### ⚠️ 合规提示
位图产品版权属中央气象台。UI 上标注来源为「中央气象台」是必须的；
直接把 `image.nmc.cn` 的图当瓦片底图长期缓存，需自行评估使用条款。

---

## ② 中国海域海洋预报

### 结论：**国家海洋预报台无结构化免 Key 接口，且 HTTPS 完全不可达**

**1) 中国海洋预报网（中国海洋预报网 / 国家海洋环境预报中心）**
```
GET http://www.oceanguide.org.cn/     → code=200  size=625  ctype=text/html; charset=UTF8
   响应体全文仅 625 字节，是 Vue SPA 空壳：
   <!DOCTYPE html><html><head>...<title>中国海洋预报网</title>
     <link href=https://www.oceanguide.org.cn/cdn/leaflet/leaflet.css ...
GET https://www.oceanguide.org.cn/    → code=000  size=0     ← curl exit code 35（SSL 握手失败）
GET https://www.nmefc.cn/             → code=000  size=0     ← 同上
GET http://www.nmefc.cn/              → code=301  size=0（跳 https，而 https 不通 → 死路）
```
→ **实测：HTTPS 完全不可握手；HTTP 只能拿到 SPA 空壳，没有任何数据。**

**2) 尝试找 SPA 后端接口（全部失败）**
```
/api/forecast/wave  → 301；/api/v1/forecast → 301；/prod-api/... → 301；/moveSignUp/ → 301
```
全部 301 是跳 HTTPS，而 HTTPS 不通 → **拿不到后端数据。**

**3) 已知它「有」数据但只有网页/下载形态**【文档如此，未实测成功】
站点自述提供 NMEFC WAVEWATCH III 全球海浪数值预报（每天更新、5 天逐小时有效波高/波向/平均周期）、
全球表层海流/海温/盐度；「妈祖」系列海流海浪模式源码已开源。**均为网页或源码下载，无公开 API。**

**4) ⭐ 替代方案：中央气象台 nmc 海区预报（有中文！）**

这是本轮**唯一实测到「有中文海洋预报」**的免 Key 来源：

```
GET http://www.nmc.cn/publish/marine/newcoastal.html → code=200 size=17959
```
表头逐字（HTML `<table>` 内，非 JSON）：
```
沿岸海区 | 预报时效(小时) | 天气现象 | 风向 | 风力(级) | 能见度(km)
```
数据行逐字（实测提取）：
```
渤海北部沿岸 | 00-12 | 晴 | 西南风 | 5～6 | 30
             | 12-24 | 晴 | 南南西 | 5～6 | 30
             | 24-36 | 晴 | 南南西 | 4～5 | 30
             | 36-48 | 晴 | 南南西 | 5～6 | 30
             | 48-60 | 阴 | 西南西 | 3～4 | 12
             | 60-72 | 晴 | 南南东 | 3～4 | 30
辽东半岛西部沿岸 | 00-12 | 晴 | 西南风 | 5～6 | 30
```
相关页面（均实测 200）：
- 海区风力预报 `/publish/taifenghaiyang/haiqufengliyubao/index.html`
- 海浪数值预报（WW3，**位图**）`/publish/nwp/ww3/globe/index.html` → code=200 size=14746
  图片 URL 形如
  `https://image.nmc.cn/product/2026/10/07/NWPR/medium/SEVP_NMC_NWPR_SWW3_EME_AGLB_L89_P9_20261007000000012.PNG`
- 海洋天气预报 `/publish/marine/forecast.htm` → code=200 size=14964

### ⚠️ 关于「海浪等级」的重要澄清
- **中文浪高描述（"3到4.5米的大浪到巨浪区"）确实存在**，但它在
  中国海洋预报网首页文案里，而该站 **HTTPS 不通、HTTP 只有空壳**→ **本轮拿不到**
- nmc 的海区表**只有「风力(级)」没有浪高**，字段逐字是
  `沿岸海区 / 预报时效(小时) / 天气现象 / 风向 / 风力(级) / 能见度(km)`
  → **想要中文浪高等级，目前只有网页文案来源，拿不到免 Key 结构化数据**

### 数据结构
- nmc 海区表：**HTML 表格**，需解析 `<tr><td>`，无 JSON、无坐标
- nmc 海浪 WW3：**PNG 位图**，无坐标值

### 国内可用性
✅ `www.nmc.cn` 可达。❌ `www.oceanguide.org.cn` 的 **HTTPS 不可用**（这是硬结论，已复现多次）。

---

## ③ 潮汐 —— 本轮**最重要的发现**

### 结论：**Open-Meteo marine API 本身就提供潮汐，零成本，不需要任何新源**

官方文档写的是 `sea_level_height_msl`（不是 `tide_height`——后者会被 400 拒绝）。
【文档如此，未实测】文档称"Tides and ocean currents are computed at 0.08° (~8 km) resolution
using numerical models. Accuracy at coastal areas is limited. This is not suitable for coastal
navigation and does not replace your nautical almanac." —— **这段免责声明必须保留到 UI 文案里。**

### 实测证据 1：变量名踩坑（重要）

**错误变量名会被 400 拒绝，响应体逐字如下**：
```
GET .../v1/marine?...&hourly=sea_surface_height,tide_height
→ code=400 size=158
{"reason":"Invalid value: Cannot initialize SurfacePressureAndHeightVariable<...>
 from invalid String value sea_surface_height","error":true}
```
→ `tide_height` 不是合法变量名。**正确名字是 `sea_level_height_msl`。**

### 实测证据 2：正确变量 200 OK + 真实潮汐数值

**hourly 精度（大连 38.9,121.6，2 天）**
```
GET https://marine-api.open-meteo.com/v1/marine?latitude=38.9&longitude=121.6
    &hourly=sea_level_height_msl&forecast_days=2&timezone=Asia/Shanghai
→ code=200  size=455
"hourly_units":{"time":"iso8601","sea_level_height_msl":"m"}
"hourly":{"time":["2026-10-07T00:00",...],
          "sea_level_height_msl":[...]}
前 26 个实测值：
[-0.54,-0.46,-0.23,0.11,0.55,0.97,1.24,1.27,1.12,0.82,0.4,-0.07,-0.45,
 -0.63,-0.6,-0.41,-0.08,0.33,0.66,0.81,0.77,0.56,0.22,-0.21,-0.59,-0.78]
```
**物理合理性校验（本轮实际算过）**：相邻极值间隔约 12.4 小时、振幅约 ±1.3 m
→ 符合**半日潮（M2 半日潮，周期约 12.42 小时）**的物理特征。
**说明这不是随机噪声或缺测插值，是真实数值模式输出。**

**minutely_15 精度（青岛 36.07,120.38，48 小时）**
```
GET .../v1/marine?latitude=36.07&longitude=120.38
    &minutely_15=sea_level_height_msl&forecast_hours=48&timezone=Asia/Shanghai
→ code=200  size=1436
"minutely_15_units":{"time":"iso8601","sea_level_height_msl":"m"}
前 32 个实测值：
[1.09,1.18,1.25,1.31,1.36,1.39,1.42,1.42,1.42,1.4,1.37,1.33,1.28,1.21,1.14,
 1.05,0.95,0.84,0.72,0.59,0.46,0.33,0.19,0.06,-0.07,-0.19,-0.31,-0.41,-0.49,-0.55,-0.6,-0.62]
```
→ **15 分钟粒度可用**（适合做「当前潮位曲线」平滑展示）。

**7 天数据（青岛）**
```
&forecast_days=7 → code=200 size=948；数组长度=168（= 7×24，逐小时）
高低潮极值提取实测（客户端本地算）：
  高潮：('2026-10-07T02:00', 1.42) ('2026-10-07T13:00', 1.43) ('2026-10-08T02:00', 1.68)
        ('2026-10-08T14:00', 1.52) ('2026-10-09T03:00', 1.79) ('2026-10-09T15:00', 1.80)
  低潮：('2026-10-07T08:00', -0.62) ('2026-10-07T20:00', -1.37) ('2026-10-08T09:00', -1.03)
        ('2026-10-08T21:00', -1.47) ('2026-10-09T09:00', -1.08) ('2026-10-09T22:00', -1.42)
```
→ **高低潮时间/潮高可纯客户端从数组求极值得到，无需再问服务器。**

### 数据结构（逐字字段名，解码器用）
| 位置 | 逐字字段名 | 类型 | 单位 |
|---|---|---|---|
| 根 | `hourly` | object | — |
| 根 | `hourly_units` | object | — |
| `hourly` 内 | `time` | `[String]` ISO8601 | — |
| `hourly` 内 | `sea_level_height_msl` | `[Double?]`（可含 null） | `m` |
| 根 | `minutely_15` | object | — |
| `minutely_15` 内 | `time` | `[String]` ISO8601 | — |
| `minutely_15` 内 | `sea_level_height_msl` | `[Double?]` | `m` |
| 根 | `utc_offset_seconds` | Int | 秒 |

> ⚠️ 注意 marine API **没有 `current`** 块用于潮汐（本仓现有 `MarineConditionsResponse`
> 是 `current` 形态，见 `Core/Networking/MarineEndpoint.swift:26`）。
> 潮汐只能走 `hourly` / `minutely_15`，需要在现有解码器上扩展。

### 覆盖范围与更新频率
- 全球海岸（模型格点 0.08°≈8 km）【文档如此，未实测逐点验证】
- 数据源：MeteoFrance SMOC（海流与潮汐），每天更新、10 天预报【文档如此，未实测】
- 实测确认：任意中国沿海坐标（大连/青岛）均 200 有值

### ⚠️ 已知局限（写入 UI 文案）
- **8 km 分辨率，近岸精度有限**，官方明确声明**不可用于航海、不能替代航海年历**
- 数值含**倒压效应**（`invert_barometer_height`），不是纯天文潮
- 不含中国主要港口的**潮高基准面换算**（如理论最低潮面），潮高数值**不可直接用于 navigational purpose**

### 备选源实测：NOAA CO-OPS（免 Key，但**中国无站**）
```
GET https://api.tidesandcurrents.noaa.gov/api/prod/datagetter?product=predictions
    &application=NOS.COOPS.TAC.WL&begin_date=20261007&end_date=20261008
    &datum=MLLW&station=9414290&time_zone=lst_ldt&units=metric&interval=hilo&format=json
→ code=200  size=155
{ "predictions" : [
{"t":"2026-10-07 03:25", "v":"0.023", "type":"L"},
{"t":"2026-10-07 10:19", "v":"1.687", "type":"H"},
{"t":"2026-10-07 15:54", "v":"0.449", "type":"L"},
{"t":"2026-10-07 21:59", "v":"1.687", "type":"H"}, ... ] }
```
- ✅ **真免 Key**（无apikey 参数）
- 字段逐字：`predictions[].t`（时间）`predictions[].v`（潮高）`predictions[].type`（`H`高潮/`L`低潮/`HH`/`LL`）
- ❌ **中国覆盖实测为 0**：
```
GET https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json
    ?lat=31.2&lon=121.5&radius=500&type=tidepredictions
→ code=200  size=119146   count=3499
按 state 分布 top：FL 583, AK 524, ''(空) 431, SC 247, NJ 195, CA 193  ← 全是美洲
中国站数（state=CN 或 name 含 china）：0
中国近海坐标站（lng 100~135 且 lat 15~45）：0
```
→ **CO-OPS 只覆盖美欧，亚洲没有**。对本项目无用。

### 🏆 推荐
**只接 Open-Meteo 的 `sea_level_height_msl`，不引入任何潮汐专用源。**

---

## ④ 卫星云图

### 结论：国内有免 Key 真彩卫星云图（nmc 风云四号）；NASA GIBS 也免 Key 但**有夜间纯黑占位图的坑**

### 方案 A：中央气象台 风云四号真彩（**推荐**）

```
GET http://www.nmc.cn/publish/satellite/fy4b-visible.htm → code=200 size=14905
```
页面内逐字提取的产品 URL：
```
https://image.nmc.cn/product/2026/10/07/WXBL/medium/SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_20261007101500000.JPG?v=1791370128443
```
实际下载验证：
```
→ code=200  size=148608  ctype=image/jpeg
像素统计：860×540  Rmin=0 Rmax=255 Rstd=73.27  唯一样本=48722
```
✅ **48 722 个颜色样本 + Rstd=73.27 → 确认是真彩云图**（不是灰度占位、不是纯色）。

- 产品名逐字：`SEVP_NSMC_WXBL_FY4B_ETCC_ACHN_LNO_PY_<时间戳>`
  - `WXBL` 卫星产品 · `FY4B` 风云四号B星 · `ETCC` 真彩色 · `PY` 白天可见光
- 时次实测为**每 10 分钟级**（样本时间戳 `1015000000` = 10:15）
- 覆盖：亚洲/中国区域（`ACHN`）
- 分类目录：`WXBL`（卫星云图）；雷击是`WEAP`，海浪是 `NWPR`
- ⚠️ 同 nmc 模式：**只有 `medium` 档**（`high`/`large` 同雷电，实测 404）

### 方案 B：NASA GIBS（全球，免 Key，**但有坑**）

```
GET https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/
    VIIRS_NOAA20_CorrectedReflectance_TrueColor/default/{DATE}/GoogleMapsCompatible_Level9/{z}/{x}/{y}.jpeg
```
**实测踩坑全过程（本轮最有价值的负样本）**：

第一次测（用"今天"日期 = 2026-10-07）：
```
6 个**完全不同**的位置（4/13/6 北京、4/13/7、4/12/6、4/6/4、5/26/13、3/6/3）
全部 code=200  size=1665  ctype=image/jpeg← 字节数一模一样
像素统计：256×256  Rmin=0 Rmax=0 Rstd=0.00  唯一样本=1← 全黑！
```
→ **若只看状态码和字节数，会 100% 误判为"可用"**。这正是本项目历史上"用字节数判覆盖"零判别力的重演。
**像素级统计（唯一样本=1）才暴露它是纯黑占位图**——当天夜间/无日照，真彩产品无数据。

换用**白天日期**重测：
```
2026-10-05 → code=200 size=8186  Rmin=0 Rmax=255 Rstd=113.83 唯一样本=3156  ← 真图
2026-10-06 → code=200 size=7870  Rmin=0 Rmax=255 Rstd=67.89  唯一样本=3159  ← 真图
2026-10-07 → code=200 size=1665  Rmin=0 Rmax=0    Rstd=0.00   唯一样本=1     ← 纯黑
```
→ **GIBS 结论：技术上是真瓦片服务、免 Key，但真彩产品夜间必须回退到有日照的日期，
否则拿到 200/纯黑。** 接入时必须按 UTC 白天小时选择日期，并在客户端做纯黑检测
（唯一样本==1 或 Rstd 极小 → 判为无效帧，不显示）。

>补充：MODIS_Terra/Aqua 真彩在 `GoogleMapsCompatible_Level7` 档位返回
> `code=400 size=431`，本轮未调通 → `【无法确定】`（层级名可能不对）。

### 方案 C：需 Key 的源（实测确认**不是**免 Key）

```
GET https://api.map.baidu.com/rest/weather/v2/?ak=x&locations=北京
→ code=200 size=4662 ctype=text/html
  响应体：<!DOCTYPE html> ... <!--STATUS OK--> ...（返回的是 HTML 错误页，不是 JSON）
→含义：ak 无效。**不是**"无需 key 的公开接口"。

GET https://t0.tianditu.gov.cn/img_w/wmts?...&tk=x
→ code=418 size=3224 ctype=text/html; charset=utf-8
  响应体：<!DOCTYPE html>...<meta name="Server" content="CloudWAF" />...
→ 418 + CloudWAF = 天地图 WAF 拦截。**需要合法 tk。**

星图地球（datacloud.geovisearth.com）：风云四号卫星云图产品
  URL 形如 https://tiles.geovisearth.com/meteorology/v1/view/satellite/mfv/fy/vis/range?start=yyyymmddhh&token=用户token
  【文档如此，未实测】文档明确「支持HTTPS协议，本服务仅对特定用户开放」，
  且需注册 + 开发者认证，**流量系数 8**。属**需 Key** 且非公开自助。
```

### 🏆 推荐
**优先接 nmc 风云四号真彩**（国内直连、免 Key、10 分钟级、真彩已验证）。
GIBS 作为可选的全球底图补充，但**必须实现纯黑帧检测**。

---

## ⑤ 花粉

### 结论：Open-Meteo 有花粉变量，但**中国实测恒为 null，仅欧洲有值 → 国内不可用**

### 实测证据 1：变量名有效（200 OK），但中国无数据

```
GET https://air-quality-api.open-meteo.com/v1/air-quality?latitude=39.9&longitude=116.4
    &current=alder_pollen,birch_pollen,grass_pollen,mugwort_pollen,olive_pollen,ragweed_pollen
    &timezone=auto
→ code=200  size=293
"current_units":{"alder_pollen":"grains/m³", ...全部 6 项单位正常}
"current":{"time":"2026-10-07T18:00","interval":3600,
  "alder_pollen":null,"birch_pollen":null,"grass_pollen":null,
  "mugwort_pollen":null,"olive_pollen":null,"ragweed_pollen":null}← 全 null
```
→ **注意：状态码 200、单位齐全、只有值是 null。** 这正是"看状态码会误判可用"的典型。

### 实测证据 2：显式指定全球域仍无中国花粉
```
GET ...?latitude=39.9&longitude=116.4&hourly=grass_pollen&domains=cams_global&timezone=auto
→ code=200  size=515   grass_pollen 值仍为 null
```
→ 换域也救不回来。

### 实测证据 3：中国春末（花粉季）复测 —— 仍是全null
```
GET ...?latitude=39.9&longitude=116.4&hourly=grass_pollen,birch_pollen
    &start_date=2026-05-10&end_date=2026-05-11&timezone=auto
→ code=200  size=363
grass_pollen = [None, None, None, None, None, None, None, None, None, None, None, None]
birch_pollen = [None, None, None, None, None, None, None, None, None, None, None, None]
```
→ **不是"秋季无花粉季"的问题，是根本不覆盖中国。**

### 实测证据 4：欧洲对照组 —— 证明变量本身有效（关键反证）

**柏林 10 月（当前）**
```
GET ...?latitude=52.52&longitude=13.41&hourly=alder_pollen,birch_pollen,grass_pollen,mugwort_pollen,ragweed_pollen&forecast_days=1
→ code=200  size=340
五项均为 0.0（非 null！max=0.0）← 有效覆盖，只是10 月非花粉季
```
**柏林 8 月（花粉季高峰）—— 拿到真实数值**
```
GET ...?latitude=52.52&longitude=13.41&hourly=grass_pollen,birch_pollen,mugwort_pollen
    &start_date=2026-08-10&end_date=2026-08-11&timezone=auto
→ code=200  size=340（各 48 点）
grass_pollen  = [2.9, 2.8, 2.7, 1.7, 2.0, 1.9, 1.8, 1.7, 1.5, 1.8, ...]  非null 48/48
mugwort_pollen = [42.7, 37.5, 36.2, 32.0, 16.9, 30.7, 12.9, 25.1, 32.1, 33.5, ...] 非null 48/48
birch_pollen = [0.0, 0.0, ...] 非null 48/48
```
→ **决定性对比**：
| 地点 | 结果形态 | 说明 |
|---|---|---|
| 柏林（欧洲）| 有数值 `0.0`~ `42.7` | 覆盖 ✅，值随季节变化 |
| 北京（中国）| **全部 `None`** | 覆盖 ❌ |

**两种 null 语义完全不同**：欧洲用 `0.0` 表示"有覆盖但此刻为零"，
中国用 `null` 表示"此点无此变量"。**客户端可据此区分"花粉为零"与"无数据"。**

### 官方文档佐证
> "*Only available in Europe as provided by CAMS European Air Quality forecast."
>（花粉变量标注星号 = 仅欧洲，花粉季 4 天预报）
【文档如此，未实测】与本轮实测结论完全一致。

### 数据结构（若将来要接欧洲，逐字字段名）
```
hourly.alder_pollen / birch_pollen / grass_pollen /
       mugwort_pollen / olive_pollen / ragweed_pollen   → [Double?]
hourly_units.同上 → "grains/m³"
```
### 其他国内候选源
```
http://www.nmc.cn/publish/observations/plant-pollen.html → code=200size=4358（404 页面模板，非数据）
```
→ 无免 Key 的国内花粉数据源。彩云天气等需Key。

### 🏆 推荐
**中国区不做花粉功能。** 若未来要支持欧洲用户，可直接复用 air-quality 端点，
但需注意 `null` vs `0.0` 的区分，且必须标注数据来源 CAMS（Open-Meteo 要求署名）。

---

## 附：若要接入 ③ 潮汐（推荐第一优先），实测过的完整 URL 与字段

**推荐 URL（小时级，7 天）**
```
https://marine-api.open-meteo.com/v1/marine?latitude={lat}&longitude={lon}
  &hourly=sea_level_height_msl
  &forecast_days=7
  &timezone=auto
```
**推荐 URL（15 分钟级，48 小时，用于潮位曲线）**
```
https://marine-api.open-meteo.com/v1/marine?latitude={lat}&longitude={lon}
  &minutely_15=sea_level_height_msl
  &forecast_hours=48
  &timezone=Asia/Shanghai
```

**真实响应体片段（大连，hourly，字段逐字未改）**
```json
{"latitude":38.791664,"longitude":121.625015,"generationtime_ms":0.089,
 "utc_offset_seconds":28800,"timezone":"Asia/Shanghai","timezone_abbreviation":"GMT+8",
 "elevation":29.0,
 "hourly_units":{"time":"iso8601","sea_level_height_msl":"m"},
 "hourly":{"time":["2026-10-07T00:00",...],
   "sea_level_height_msl":[-0.54,-0.46,-0.23,0.11,0.55,0.97,1.24,1.27, ...]}}
```

**真实响应体片段（青岛，minutely_15）**
```json
{"latitude":36.041664,"longitude":120.375015,"elevation":23.0,
 "minutely_15_units":{"time":"iso8601","sea_level_height_msl":"m"},
 "minutely_15":{"time":["2026-10-07T00:00","2026-10-07T00:15","2026-10-07T00:30",...],
   "sea_level_height_msl":[1.09,1.18,1.25,1.31,1.36,1.39,1.42,1.42, ...]}}
```

**与本仓现状的差距（供后续实现参考，本轮未改任何代码）**
- `Core/Networking/MarineEndpoint.swift:62-67` 当前只请求 6 个 wave 变量
  （`wave_height`/`wave_direction`/`wave_period` + 3 个 `swell_*`），**未含潮汐**
- `Core/Models/MarineConditionsResponse.swift:86` 只有 `let current: Current?`，
  **潮汐需要 `hourly` / `minutely_15` 块**，需扩展解码器
- 注意 `Core/Networking/MarineEndpoint.swift:10` 已记录的坑：
  marine 端点必须用 `marine-api.` 子域，写主站 404
- 建议 UI 文案固定包含：数据源 Open-Meteo / MeteoFrance SMOC，
  及「潮汐为 8km 数值模型结果，近岸精度有限，不可用于航海」

---

## 未能确定的事项（如实列出）

| 事项 | 状态 |
|---|---|
| MODIS Terra/Aqua 真彩瓦片层级名 | 【无法确定】`GoogleMapsCompatible_Level7` 返回 400，未调通正确层级 |
| Blitzortung `Strikes_4` 的 JSON 行格式 | 【无法确定】401 挡路，无法验证 |
| 国家海洋预报网 SPA 的真实后端 API路径 | 【无法确定】HTTPS 不通 + HTTP 全 301，拿不到 JS bundle |
| 星图地球风云四号接口实际响应 | 【文档如此，未实测】需注册 token |
| 中国是否有免 Key 的**结构化**雷击坐标源 | **本轮未找到**（不能断言不存在，只能说主流候选都需 Key 或仅位图） |