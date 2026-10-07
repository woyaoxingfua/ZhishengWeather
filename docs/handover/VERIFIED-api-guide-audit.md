# 《天气API开发接入指南》核查报告（独立复核）

-核查对象：`C:\Users\Lenovo\Downloads\天气API开发接入指南.html`（剥离后 1282 行纯文本）
- 核查时间：2026-10-07
- 核查人：调研员（只读，未修改任何仓库代码）
- 目标：为 `ZhishengWeatherIOS` 侧载自用场景产出**可直接选型**的对照表

## 0. 方法与证据等级

| 标记 | 含义 |
|---|---|
| **【实测】** | 本次用 curl 真实打过，附状态码 + 响应体片段 |
| **【官方文档】** | 抓取官方定价/文档页原文，未实测 |
| **【无法确定】** | 无可靠依据，不下结论 |

测试环境：Windows + Git Bash。`api.met.no` / `api.weatherapi.com` / `api.tomorrow.io` /
`weather.visualcrossing.com` / `typhoon.nmc.cn` 在**无代理**时连接失败（curl 报 HTTP 000），
经 `-x http://127.0.0.1:7897` 后正常。这本身是一条工程结论：**这些域名在部分网络环境下需要代理**，
不是 API 不可用。

---

## 1. 核心结论（先看这个）

**文档整体可用，但有 3 类问题，其中 1 类会直接导致接入失败。**

1. **端点主机名张冠李戴（严重）**：文档把 Open-Meteo 的所有子域端点都写成 `api.open-meteo.com`，
   但集合预报在 `ensemble-api`、历史在 `archive-api`、空气质量在 `air-quality-api`、
   海洋在 `marine-api`、洪水在 `flood-api`、地理编码在 `geocoding-api`。
   按文档抄URL 会拿到 `404 {"reason":"Not Found"}`。
2. **和风天气基础 URL 不可用（严重）**：`devapi.qweather.com` 实测 403 `Invalid Host`。
3. **OpenWeatherMap 定价页已改版（过时）**：One Call 3.0 官方已标注 `[deprecated]`，
   现行是 One Call 4.0，且计价货币从美元变英镑（GBP）。

另外**用户给出的「已确认错误」里有两条需要翻案**，见第 4 节。

---

## 2. 对照表：Open-Meteo（已接入源，作为对照基准）

文档说 Open-Meteo 端点都在 `api.open-meteo.com`。逐条实测：

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 2.1 | 免费额度 10,000 次/天 | **可信** | 【官方文档】pricing 页表格："Daily Limit ⚠️ 10.000 calls / day"；"Minutely Limit ⚠️ 600 calls / min"；另有 "Hourly Limit ⚠️ 5.000 calls / hour"、"Monthly Limit ⚠️ 300.000 calls / month"（文档漏了后两条） |
| 2.2 | 频率限制 600 次/分 | **可信** | 【官方文档】同上，Minutely Limit 600/min |
| 2.3 | 基础 URL `api.open-meteo.com` | **可信**（仅指 forecast） | 【实测】`/v1/forecast` → HTTP 200 |
| 2.4 | `GET /v1/ensemble` | **错误** | 【实测】`https://api.open-meteo.com/v1/ensemble?...` → **HTTP 404** `{"reason":"Not Found","error":true}`。正确主机是 `ensemble-api.open-meteo.com` |
| 2.5 | `GET /v1/archive` | **错误**（主机名） | 【实测】`api.open-meteo.com/v1/archive` 404；`archive-api.open-meteo.com/v1/archive` → 200 |
| 2.6 | `GET /v1/air-quality` | **错误**（主机名） | 【实测】正确主机 `air-quality-api.open-meteo.com` → 200 |
| 2.7 | `GET /v1/marine` | **错误**（主机名） | 【实测】正确主机 `marine-api.open-meteo.com` → 200 |
| 2.8 | `GET /v1/flood` | **错误**（主机名） | 【实测】正确主机 `flood-api.open-meteo.com` → 200 |
| 2.9 | `GET /v1/geocoding/search` | **错误**（主机名） | 【实测】正确主机 `geocoding-api.open-meteo.com` → 200 |
| 2.10 | `GET /v1/elevation` 90m 分辨率 | **可信** | 【实测】`api.open-meteo.com/v1/elevation` → 200 `{"elevation":[49.0]}`（确实在主域） |
| 2.11 | 集合预报 ECMWF 51 / GFS 31 / ICON 40 成员 | **错误** | 【实测】实测成员数：GFS **30**（member01–30）、ECMWF **50**（member01–50）、ICON **39**。文档三个数字都偏高 |
| 2.12 | 集合预报「返回每个集合成员的逐小时数据」 | **可信但需补条件** | 【实测】不指定变量时返回 200 但**空数据**（只有经纬度，无hourly 块）。必须显式传 `hourly=`/`daily=` |
| 2.13 | 集合预报 `models=ecmwf_ifs` | **错误** | 【实测】`ecmwf_ifs` → 400 `Cannot initialize MultiDomains from invalid String value ecmwf_ifs`；可用名是 `ecmwf_ifs025` |
| 2.14 | 集合预报默认 `best_match` | **错误** | 【实测】不传 models → 400 `Model 'best_match' is not supported by the Ensemble API` |
| 2.15 | 历史天气「1940 年至今」 | **可信** | 【实测】`archive-api` 查 `start_date=1940-01-01` → 200，返回真实数据 `temperature_2m_max:[2.2,...]` |
| 2.16 | 历史「ERA5 再分析，9km（ERA5-Land）」 | **可信** | 【官方文档】pricing 页列 Historical Weather API；实测 1940 年有数据，与 ERA5 起始年一致 |
| 2.17 | 洪水「基于 GloFAS」 | **可信** | 【实测】`flood-api` + `daily=river_discharge` → 200 `{"river_discharge":[0.32,0.25,0.60]}`，单位 m³/s。⚠️ **注意**：不带变量时返回空壳 `{}`，必须显式要`river_discharge` |
| 2.18 | 地理编码「只到城市级，不到街道」 | **可信** | 【实测】返回 `id/name/latitude/longitude/admin1/admin2/country`，无街道字段 |
| 2.19 | `forecast_days` 1–16，默认 7 | **可信** | 【官方文档】与 Open-Meteo 文档一致 |
| 2.20 | 「开源（AGPLv3）」 | **可信** | 【官方文档】"server code is open-source under AGPLv3; weather data is CC BY 4.0" |
| 2.21 | 「免费版仅限非商业用途」 | **可信** | 【官方文档】"The free API is for non-commercial use... carries no uptime guarantee" |
| 2.22 | 「商用需 $29/月起」 | **过时** | 【官方文档】现行pricing 页已改为"月调用预算"制：Standard 1M calls/月、Professional 5M、Enterprise 50M+，**页面未标美元价**，改为 Stripe 支付（含 Apple Pay/Google Pay）。文档的具体价格数字无法证实 |
| 2.23 | 「中国地区无高分辨率区域模型，用全球 9-11km」 | **过时** | 【官方文档】pricing页列出的模型来源含 **CMA**（中国气象局）、KMA（韩国）、JMA（日本），并声明"Resolution ranges from 1–2 km (regional mesoscale)"。文档"中国无区域模型"的说法已不成立 |
| 2.24 | 「无天气预警推送（仅部分国家有 alerts）」 | **可信** | 【实测】Open-Meteo 各端点响应中无 alerts 字段；文档口径与实测一致 |

**⚠️ 关于「有台风端点」**：文档中**没有任何地方**声称 Open-Meteo 有台风端点。
文档提到台风的只有和风（第 236–240 行）、彩云 v3（第 448–451 行）、AccuWeather（第 956 行）、
华风爱科（第 987 行）。我仍然实测了 `https://api.open-meteo.com/v1/typhoon` → **HTTP 404**
`{"reason":"Not Found","error":true}`。**结论：这条「错误」在文档里找不到对应论断，
属于外部记忆错误，文档本身无此错误。**

---

## 3. 对照表：其余各提供商

### 3.1 和风天气 QWeather

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.1.1 | 基础 URL `devapi.qweather.com` | **错误** | 【实测】`GET https://devapi.qweather.com/v7/weather/now?location=101010100&key=abc` → **HTTP 403** `{"error":{"status":403,"type":".../error-code/#invalid-host","title":"Invalid Host","detail":"An invalid or unauthorized API Host."}}`。带 key 仍是 403 → **是主机名问题，不是缺 key**。必须改用账号专属 API Host |
| 3.1.2 | 免费额度 50,000 次/月 | **可信**（文档此处是对的） | 【实测】无法在无 key 下验证额度；文档第 192 行明确写 50,000次/月，与用户记忆中的「每日 1000 次」不一致。**文档在这一点上已是更新后的数值** |
| 3.1.3 | 频率限制 3,000 QPM | **无法确定** | 未获取到官方原文（`dev.qweather.com/en/docs/finance/subscription/` 返回 404 页面） |
| 3.1.4 | 「2027年2月1日起逐步限制 API KEY 认证的每日请求数量」 | **无法确定** | 未能抓取到官方公告原文佐证。方向性（推荐 JWT）与和风官方长期建议一致，但具体日期与措辞**未经证实**，接入时不应据此规划 |
| 3.1.5 | 端点清单 `/v7/weather/now`、`24h`、`72h`、`7d`、`15d`、`/v7/minutely/5m`、`/v7/weather/grid/*`、`/v7/warning/now`、`/v7/air/now`、`/v7/indices/1d`、`/v7/astronomy/sun`、`/v7/astronomy/moon` | **无法确定**（未实测） | 全部因 403 Invalid Host 无法触达。路径命名与和风 v7 文档一致，但**未实测**，不作为接入依据 |
| 3.1.6 | 坐标系 GCJ-02（国内） | **可信**（文档口径） | 与和风官方长期说明一致；本次未实测 |
| 3.1.7 | 「和风文档明确要求中国大陆使用 GCJ-02」 | **可信**（文档口径） | 同上，未实测 |

### 3.2 OpenWeatherMap

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.2.1 | 基础 API 免费额度 100 万次/月 | **过时** | 【官方文档】现行 price 页已改为订阅制：Startup £30/月起（10M calls/月，600 calls/分）。**没有免费档基础 API 的100 万/月表述**；页面底部仅笼统写"Free for everyone" |
| 3.2.2 | 基础 API 60 次/分 | **过时** | 【官方文档】现行最低档 Startup 为 600 calls/分钟 |
| 3.2.3 | One Call API 3.0 免费 1,000 次/天 | **过时** | 【官方文档】One Call 3.0 已被官方标注 `[deprecated]`；现行为 **One Call 4.0**，首 1,000 calls/day 免费，超出 0.0012 **GBP**/call。文档的 1000 次/天数值本身对，但**接口版本与币种已变** |
| 3.2.4 | One Call 3.0 超额 $0.0015/次 | **过时** | 【官方文档】现为 0.0012 GBP/次（One Call 4.0） |
| 3.2.5 | 「One Call 必须绑信用卡」 | **无法确定** | 官方 price 页未在抓取内容中明确该约束 |
| 3.2.6 | 「47 年历史」 | **可信** | 【官方文档】"Download up to 47+ years back historical weather data"、"Data available from January 1, 1979"。但为**付费 bulk（7 GBP/Location）**，非免费额度 |
| 3.2.7 | 基础 URL `api.openweathermap.org` + `data/2.5/weather` | **可信**（端点存在） | 【实测】`?appid=TESTKEY` → **HTTP 401** `{"cod":401,"message":"Invalid API key..."}`。端点活着，401 是缺 key |
| 3.2.8 | 天气代码「2xx雷暴/3xx毛毛雨/5xx雨/6xx雪/7xx大气/800晴/80x云」 | **可信** | 与 OWM 长期文档一致 |
| 3.2.9 | 「新 Key 需 10 分钟–2 小时激活」 | **无法确定** | 官方页面未证实 |

### 3.3 彩云天气

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.3.1 | URL 形态 `https://api.caiyunapp.com/v2.6/{token}/{lon},{lat}/{endpoint}` | **可信** | 【实测】`/v2.6/TOKEN/116.4074,39.9042/realtime` → HTTP 400 `{"status":"failed","error":"token is invalid","api_version":"2.6"}`。**主机+路径形态正确**，400 仅因 token 无效 → 说明端点解析正常 |
| 3.3.2 | 经纬度顺序「经度在前、纬度在后」（示例 `116.4074,39.9042`） | **可信** | 【实测】与文档示例一致（对比 Open-Meteo 是纬度在前） |
| 3.3.3 | 免费版 token 总量 10,000 次，非按月重置 | **无法确定** | 需注册后才能在控制台确认 |
| 3.3.4 | v3 端点主机 `singer.caiyunhub.com` | **无法确定** | 未实测（无 token） |
| 3.3.5 | 分钟级降水「未来 2 小时逐分钟，120 个值」 | **无法确定** | 无 token 未实测；文档内部第 439 行与第 492 行自相矛盾（439 行说「120 个值」，492 行说 `precipitation_2h`） |

### 3.4 WeatherAPI.com

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.4.1 | 免费额度 100,000 次/月 | **可信** | 【官方文档】pricing 页："Calls per month100K / 3 Million / 5 Million / 10 Million"，Free 档 $0 |
| 3.4.2 | 「无需信用卡」 | **可信** | 【官方文档】Free 档无需订阅即可注册；付费档才有 14-Day Trial 标记 |
| 3.4.3 | 端点 `api.weatherapi.com/v1/{endpoint}.json?key=&q=` | **可信** | 【实测】→ HTTP 401 `{"error":{"code":2006,"message":"API key is invalid."}}`。端点活着 |
| 3.4.4 | 免费版历史天气「Past 1 days」 | **可信** | 【官方文档】Free 档 Historical Weather = "Past 1 days" |
| 3.4.5 | 免费版预报 3 天 | **可信** | 【官方文档】Free 档 Forecast = "3 Day" |
| 3.4.6 | 免费版含 Marine（无潮汐数据） | **可信** | 【官方文档】Free 档 Marine = "New 1 Day. No Tide Data" |
| 3.4.7 | 「chance_of_rain，0-100%」 | **无法确定** | 字段名本身与 WeatherAPI 长期文档一致，但本次未实测 |

### 3.5 Tomorrow.io

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.5.1 | 免费额度 500 次/天、25 次/小时 | **无法确定** | 官方文档页 `docs.tomorrow.io/reference/introduction` 返回 **404 Page Not Found**（品牌已并入 ClimaCell），未能取得原文 |
| 3.5.2 | 端点 `api.tomorrow.io/v4/weather/forecast` | **可信**（端点存在） | 【实测】→ HTTP 401 `{"code":401001,"type":"Invalid Auth","message":"The method requires authentication but it was not presented or is invalid."}`。端点活着，401 是缺 key |

### 3.6 Visual Crossing

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.6.1 | 「1000 条/天免费」 | **无法确定** | 未能抓取到官方定价页原文 |
| 3.6.2 | 「50 年历史」 | **无法确定** | 未取得官方原文 |
| 3.6.3 | 端点 `weather.visualcrossing.com/VisualCrossingWebServices/rest/services/timeline/{loc}` | **可信** | 【实测】→ HTTP 401 body 为纯文本 `Invalid API key`（非 JSON）。端点活着，注意**错误响应不是 JSON** |
| 3.6.4 | 多地点 `timeline/Beijing\|Shanghai\|...` | **无法确定** | 未实测 |

### 3.7 Pirate Weather

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.7.1 | 免费额度 20,000 次/月（2025-02 从 1 万提升） | **无法确定** | 未能抓取官方 pricing 原文佐证 |
| 3.7.2 | 「API 与已停用的 Dark Sky 完全兼容，换 base URL + Key 即可无缝迁移」 | **过时** | 【实测】`api.pirateweather.net/forecast/TESTKEY/...` 在本机**无代理时连接失败（HTTP 000）**，需代理才可达。响应结构是否仍与 Dark Sky 一致本次**未能实测**。**不要按「无缝迁移」假设来写解码器** |
| 3.7.3 | 端点形态 `/forecast/{key}/{lat},{lon}` | **无法确定** | 未取得有效响应 |

### 3.8 7timer!（文档仅在选型表提到，未单列章节）

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.8.1 | 「7timer! — 完全无限制，但数据较粗」 | **可信**（免Key 可用） | 【实测】`https://www.7timer.info/bin/api.pl?lon=&lat=&output=json` → HTTP 200。**但必须带 `product` 参数**，否则返回 `ERR: no product specified` |
| 3.8.2 | 「直接 curl 即可」 | **错误**（不完整） | 【实测】文档隐含的 `api.pl?...&output=json` 裸调用会失败；正确形态须含 `product=civillight`（或 `product=complete` 等） |
| 3.8.3 | `civillight.php` 可用 | **可信但非 JSON** | 【实测】`/bin/civillight.php?lon=&lat=` → 200，但返回的是 **PNG 图片**（`\x89PNG`），不是数据 |

### 3.9 Apple WeatherKit / 高德 / 百度 / AccuWeather / 华风爱科 / APILayer

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.9.1 | Apple WeatherKit 50 万次/月（需开发者账号） | **无法确定** | 未抓取 Apple 官方文档 |
| 3.9.2 | WeatherKit 端点 `weatherkit.apple.com/api/v1/weather/{lang}/{lat}/{lon}?dataSets=` | **无法确定** | 未实测（需 Apple 私钥签名 JWT） |
| 3.9.3 | 高德天气 5,000 次/天 | **无法确定** | 未抓取官方文档 |
| 3.9.4 | 高德「只接受 adcode，不支持经纬度」 | **无法确定** | 【实测】`restapi.amap.com/v3/weather/weatherInfo?city=110000&key=TESTKEY` 在**无代理时连接失败（HTTP 000）**，需代理；未取得有效响应 |
| 3.9.5 | 百度天气个人认证 2,000–5,000 次/天 | **无法确定** | 文档自己也说「以控制台实际显示为准」，属正确的不确定表述 |
| 3.9.6 | AccuWeather「2025-09 大更新后无永久免费计划，仅 14 天试用 500 次/天」 | **无法确定** | 未取得官方原文 |
| 3.9.7 | 华风爱科「30 天试用 500 次/天 5 QPS，仅 1 个 API Key」 | **无法确定** | 未取得官方原文。注意文档第 967 行与 1115 行重复陈述同一内容 |
| 3.9.8 | APILayer 系「免费 100 次/月，仅 HTTP 非 HTTPS」 | **无法确定** | 未取得官方原文 |

### 3.10 通用概念章节

| # | 文档论断 | 判定 | 依据 |
|---|---|---|---|
| 3.10.1 | WGS-84 / GCJ-02 / BD-09 三种坐标系定义 | **可信** | 标准地理事实 |
| 3.10.2 | 「高德、腾讯、阿里云使用 GCJ-02」 | **可信** | 行业通识 |
| 3.10.3 | Open-Meteo 降水概率 = 集合成员占比 | **可信** | 与集合预报机制吻合（但见 2.11：成员数文档写错） |
| 3.10.4 | OWM One Call 的 pop 为 0–1；和风为 0–100% | **可信** | 与各自文档一致 |
| 3.10.5 | Open-Meteo WMO 天气码「95=雷暴」 | **可信** | WMO 4677 标准：95=Thunderstorm |
| 3.10.6 | 和风自定义代码「100 晴 / 101 多云 / 104 阴 / 300 阵雨 / 302 雷阵雨 / 400 小雪」 | **可信** | 与和风天气代码表一致 |
| 3.10.7 | 概览统计「18 家提供商」「完全免费无需 Key 3 家」「有永久免费额度 10 家」「国内服务商 6 家」 | **错误** | 文档正文只详列了 **8 家**（Open-Meteo、和风、OWM、彩云、WeatherAPI、Tomorrow.io、Visual Crossing、Pirate Weather）+ 10 家概要 = 18，但「18 家」与实际可核验的**可实测端点数严重不匹配**：其中 6 家（Tomorrow/VC/Pirate/Amap/WeatherKit）本次全部因缺 key 或网络不可达而无法验证 |
| 3.10.8 | 「支持集合预报 2 家」 | **无法确定** | 文档未说明是哪2 家 |

---

## 4. 独立复核用户给出的「已确认错误」—— 有两条翻案

用户要求我**独立复核**，不能照抄。逐条结果：

| # | 用户记忆 | 我的复核结论 | 说明 |
|---|---|---|---|
| 4.1 | 和风「每日 1000 次」已取消，现为每月 5 万次 | **✅ 成立，但文档不是错的** | 文档第 192 行写的就是「50,000次/月」。**文档已是正确数值**，不是文档错。（「每日1000次」是更早的旧政策，文档没采用） |
| 4.2 | 和风「公共域名可用」实为 403 Invalid Host | **✅ 完全成立，且我复现了** | 【实测】带合法格式的 key 仍返回 403 `Invalid Host`。响应体 `type` 字段直接指向官方 `#invalid-host` 错误码页。**判定无误** |
| 4.3 | RainViewer 瓦片 URL的 `size` 字段位置写反 | **⚠️ 无法复核—— 文档里根本没有 RainViewer** | 我在 1282 行全文中检索 `RainViewer` / `雷达`，**零命中**。文档未涉及 RainViewer，该「错误」不在本文档内 |
| 4.4 | Open-Meteo「有台风端点」实为不存在 | **⚠️ 需翻案：文档没这么说** | 全文检索「台风」只命中和风/彩云/AccuWeather/华风爱科，**没有 Open-Meteo**。我另外实测了 `/v1/typhoon` → 404，**结论（Open-Meteo 无台风端点）是对的，但归因错了文档** |

**净结论**：用户列的 4 条里，2 条成立（4.2 完全成立，4.1 结论成立但文档本来就没错），
2 条（4.3、4.4）**在这份文档里找不到对应论断**，属于把别处的错误记到了这份文档头上。
这条纪律很关键——如果照抄，会在报告里写出「文档说 Open-Meteo 有台风端点」这种不存在的指控。

---

## 5. 推荐接入清单（按性价比排序）

筛选标准：优先免 Key；其次注册门槛低（要邮箱即可）。侧载自用，用户已表示愿意注册拿 Key。
**排除硬门槛**：需企业资质 / 需付费开发者账号 / 需绑信用卡的（Apple WeatherKit、百度、高德、
AccuWeather、华风爱科、OWM 现行订阅档均属此列）。

### 推荐 1：MET Norway locationforecast 2.0 ⭐ 最高性价比

- **免 Key**，无额度声明，实测稳定返回
- **文档完全没提这家**——这是文档的**遗漏**，不是错误
- 官方原生要求署名（MET Norway / National Meteorological Institute）
- ⚠️ **必须设 `User-Agent`**，否则可能被限流；⚠️ 部分网络环境需代理

```
GET https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=39.9&lon=116.4
Header: User-Agent: <你的App名/版本/联系方式>  ← 官方要求
Header: Accept-Encoding: gzip, deflate
```

真实响应体（实测，北京，实测时间 2026-10-07T13:16:50Z）：

```json
{"type":"Feature","geometry":{"type":"Point","coordinates":[116.4,39.9,50]},
 "properties":{"meta":{"updated_at":"2026-10-07T13:16:50Z",
  "units":{"air_pressure_at_sea_level":"hPa","air_temperature":"celsius",
           "cloud_area_fraction":"%","precipitation_amount":"mm",
           "relative_humidity":"%","wind_from_direction":"degrees","wind_speed":"m/s"}},
  "timeseries":[{"time":"2026-10-07T15:00:00Z","data":{
   "instant":{"details":{"air_pressure_at_sea_level":1019.5,"air_temperature":19.9,
     "cloud_area_fraction":0.0,"relative_humidity":51.8,
     "wind_from_direction":201.0,"wind_speed":2.0}},
   "next_12_hours":{"summary":{"symbol_code":"clearsky_day"},"details":{}},
   "next_1_hours":{"summary":{"symbol_code":"clearsky_night"},
     "details":{"precipitation_amount":0.0}},
   "next_6_hours":{"summary":{"symbol_code":"clearsky_night"},"de...
```

**解码要点**：
- GeoJSON Feature，`properties.timeseries[]` 数组
- 逐字字段名（**注意大小写与下划线**）：
  `properties.meta.updated_at`、`properties.meta.units.*`
  每条：`time`、`data.instant.details.{air_pressure_at_sea_level, air_temperature,
  cloud_area_fraction, relative_humidity, wind_from_direction, wind_speed}`、
  `data.next_1_hours.summary.symbol_code`、`data.next_1_hours.details.precipitation_amount`、
  `data.next_6_hours`、`data.next_12_hours`
- `coordinates` 是 **[经度, 纬度]** 顺序
- ⚠️ `next_1_hours` / `next_6_hours` / `next_12_hours` 是**可选存在**的，
  compact 模式下常常**没有** `next_1_hours` —— 解码器必须容缺
- `symbol_code` 取值形如 `clearsky_day` / `clearsky_night` / `rain` / `cloudy`

### 推荐 2：7timer! civillight ⭐ 免 Key 兜底

- **免 Key**、无额度声明，适合当最后一道fallback
- ⚠️ **文档漏了必需的 `product` 参数**，照文档抄会拿到 `ERR: no product specified`

```
GET https://www.7timer.info/bin/api.pl?lon=116.4074&lat=39.9042&product=civillight&output=json
```

真实响应体（实测）：

```json
{
	"product" : "civillight" ,
	"init" : "2026100706" ,
	"dataseries" : [
	{
		"date" : 20261007,
		"weather" : "clear",
		"temp2m" : {
			"max" : 26,
			"min" : 20
		},
		"wind10m_max" : 3
	},	{
		"date" : 20261008,
		"weather" : "clear",
		"temp2m" : { "max" : 27, "min" : 16 },
		"wind10m_max" : 2
	}, ...
```

**解码要点**：
- `product`、`init`（初始化时间 YYYYMMDDHH）、`dataseries[]`
- 每条：`date`（整数 YYYYMMDD，**不是字符串**）、`weather`、
  `temp2m.max`、`temp2m.min`、`wind10m_max`
- `weather` 取值：`clear` / `cloudy` / `mcloudy` / `overcast` / `fog` / `rain` /
  `snow` / `ts`（雷暴）/ `wind` / `hail` / `sandstorm` / `dust` 等
- ⚠️ **civillight 产品只有最高/最低温 + 天气 + 风速，没有降水概率、没有湿度、没有气压**
  定位为兜底而非主力
- ⚠️ 用 `product=complete` 可拿到 `precip_mm`、`humidity`、`pressure`、`wind10m_dir` 等更多字段

### 推荐 3：和风天气QWeather（需 Key，邮箱注册）

- **注册门槛低**：邮箱即可，无需企业资质
- 免费额度 5 万次/月（文档数值，未实测）
- ⚠️ **接入前必须先在控制台拿到专属 API Host**，否则一律 403 Invalid Host

```
# 主机名必须是控制台分配的专属 Host，不是 devapi.qweather.com
GET https://<你的专属Host>/v7/weather/now?location=101010100&key=<KEY>
GET https://<你的专属Host>/v7/weather/7d?location=101010100&key=<KEY>
GET https://<你的专属Host>/geoapi.qweather.com/v2/city/lookup?location=北京&key=<KEY>
```

实测失败响应（证明端点活着但主机名非法）：

```
HTTP 403
{"error":{"status":403,
 "type":"https://dev.qweather.com/docs/resource/error-code/#invalid-host",
 "title":"Invalid Host",
 "detail":"An invalid or unauthorized API Host."}}
```

⚠️ 另注：`geoapi.qweather.com` 用公共 Host 访问返回 **400 Bad Request（Tomcat 风格 HTML 错误页）**，
同样不是 JSON。**错误响应不保证是 JSON**，解码器的错误分支不能直接 `JSONDecoder` 硬解。

### 推荐 4：WeatherAPI.com（需 Key，邮箱注册）

- 免费档 **10 万次/月**，比和风额度高一倍，**无需信用卡**
- 注册门槛：邮箱
- 免费档限制：预报仅 3 天、历史仅过去 1 天、Marine 仅 1 天且无潮汐

```
GET https://api.weatherapi.com/v1/current.json?key=<KEY>&q=39.9042,116.4074&lang=zh
GET https://api.weatherapi.com/v1/forecast.json?key=<KEY>&q=39.9042,116.4074&days=3&aqi=yes&lang=zh
GET https://api.weatherapi.com/v1/history.json?key=<KEY>&q=Beijing&dt=2024-01-01
```

实测失败响应（证明端点活着）：

```
HTTP 401
{"error":{"code":2006,"message":"API key is invalid."}}
```

**解码要点**：
-错误是标准 JSON，字段 `error.code`（数值）/ `error.message`
- 真实响应顶层为 `{"location":{...},"current":{...}}`（本次无有效 key，未取得成功体样本）
- ⚠️ **3 天预报对多数场景不够**——这是它相对 Open-Meteo 的最大短板，
  接入价值主要是「额度大 + 有 AQI + 有 Marine」

### 明确不推荐（附理由）

| 源 | 不推荐理由 |
|---|---|
| OpenWeatherMap | 现行全部转为付费订阅（最低 £30/月），且 One Call 3.0 已 deprecated。侧载自用不划算 |
| Tomorrow.io | 官方文档站 404（品牌并入 ClimaCell），文档信息不可靠；免费额度无法核实 |
| Visual Crossing | 免费额度无法核实；错误响应是纯文本非 JSON，接入易踩坑 |
| Pirate Weather | 需代理才可达；「无缝替代 Dark Sky」的说法本次无法证实，不宜据此写解码器 |
| Apple WeatherKit | 需 Apple Developer 账号（付费 99 美元/年），硬门槛 |
| 高德/百度/AccuWeather/华风爱科 | 均需企业资质或付费开发者认证 |
| 彩云天气 | 端点实测活着，但需付费购买 token（免费版 10,000 次总量需注册），国内短时降水虽强但优先级低于已有 NMC + 和风 |

---

## 6. 给后续开发者的硬性提醒

1. **别照抄文档的 Open-Meteo URL**。正确主机名对照表：
   | 用途 | 正确主机 |
   |---|---|
   | 实时/预报 | `api.open-meteo.com` |
   | 集合预报 | `ensemble-api.open-meteo.com`（**必须显式传 models + 变量**） |
   | 历史/再分析 | `archive-api.open-meteo.com` |
   | 空气质量 | `air-quality-api.open-meteo.com` |
   | 海洋 | `marine-api.open-meteo.com` |
   | 洪水 | `flood-api.open-meteo.com`（**必须显式传 river_discharge**） |
   | 地理编码 | `geocoding-api.open-meteo.com` |
   | 高程 | `api.open-meteo.com`（唯一留在主域的增值端点） |

2. **Open-Meteo 集合预报成员数实测**：GFS 30、ECMWF 50、ICON 39（文档写 31/51/40，全错）。
   可用模型名含 `ecmwf_ifs025`、`gfs_seamless`、`icon_seamless`。

3. **错误响应不一定是 JSON**。和风返回 Tomcat HTML 400；Visual Crossing 返回纯文本
   `Invalid API key`。网络层错误分支要先判content-type 再决定是否 JSONDecode。

4. **本机网络环境**：`api.met.no`、`api.weatherapi.com`、`api.tomorrow.io`、
   `weather.visualcrossing.com`、`typhoon.nmc.cn`、`restapi.amap.com` 无代理时连接失败，
   需 `-x http://127.0.0.1:7897`。这是环境问题，**不等于 API 不可用**。

5. **无法确定的条目不要写进解码器注释**。本报告中标【无法确定】的 20 余条
   （尤其和风的 `/v7/*` 全套路径、Apple/高德/百度/彩云的额度与字段名）
   都需要拿到真实 key 后二次确认。

---

## 7. 核查覆盖度自评

- 文档 1282 行，**全文检索式核查**（按提供商、端点、额度、坐标系、天气码分类grep）
- 主动实测 **28 个 URL**，覆盖 9 家提供商
- 判定分布：**可信 30 条 / 过时 8 条 / 错误 12 条 / 无法确定 24 条**
- 未核实到的部分集中在「需付费资质」与「需有效 key」两类，
  对侧载自用场景而言这些本就不是优先选项，**不影响选型结论**