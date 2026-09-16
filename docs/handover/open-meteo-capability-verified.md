# Open-Meteo 能力实测（2026-09-11，北京坐标，全部 200 OK）

> 本文件是功能对齐 PRD/架构的事实依据：以下字段**全部验证可用、免 key**。

## 1. air-quality-api.open-meteo.com（独立域名，CAMS 模型）

`GET /v1/air-quality?latitude=&longitude=&current=european_aqi,pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,sulphur_dioxide,ozone,us_aqi&timezone=auto`

- ✅ european_aqi / us_aqi 双标准
- ✅ 六项分测：pm10, pm2_5, carbon_monoxide, nitrogen_dioxide, sulphur_dioxide, ozone
- ✅ 支持 hourly / forecast_days
- 实测北京：european_aqi=53, pm10=93.1, pm2_5=30.9, co=552.0

## 2. api.open-meteo.com/v1/forecast 扩展字段

**current 可加**：visibility, dew_point_2m, cloud_cover, wind_gusts_10m, surface_pressure, pressure_msl ✅

**minutely_15 降水**（对应本体"未来两小时降水"）：
`minutely_15=precipitation,precipitation_probability&forecast_minutely_15=8`（8×15min=2h）✅

> ⚠️ **事实更正（第二轮实测，2026-09-16）**：`forecast_minutely_15` **必须显式传**，
> 否则继承 `forecast_days` 窗口（`forecast_days=1`→96 条；本工程 16 天→约 1600 条）。
> 更重要：**中国属"非原生覆盖区"，其 minutely_15 由逐小时插值到 15 分钟网格，
> 不是实况外推 / nowcast**。原生仅北美（NOAA HRRR）与中欧（ICON-D2 / AROME）。
> **数组长度无法区分原生与插值**（柏林与杭州同为 96 条），故绝不可据条数推断数据质量。
> UI 文案必须标注「由逐小时插值，非实况外推」，**禁止**"分钟级 / 雷达临近"措辞。
> 详见 `PRD-zhisheng-ios-API-expansion.md` §11-1。

**daily 可加**：sunrise, sunset, uv_index_max, daylight_duration ✅
（日出日落无需自算，API 直接给）

**hourly 可加**（本体 WeatherRepository 同款字段）：wind_gusts_10m, precipitation_probability, precipitation, surface_pressure, visibility, dew_point_2m, cloud_cover, uv_index ✅（原仓库 OpenMeteoApi.kt:43-46 同参数）

## 3. 结论

- 第一批（纯 Open-Meteo）：空气质量六项+AQI、**15 分钟粒度 2h 降水（中国为逐小时插值，非 nowcast）**、气压/能见度/露点/云量/阵风/UV、日出日落 → **全部零凭据可做**
- 气象预警：Open-Meteo 无此能力 → 需国内源（和风/彩云凭据），排第三批
- 生活指数：Open-Meteo 无现成，但 UV/温湿度/风速都有了 → 可本地计算（第二批）
- 历史天气/昨日对比：Open-Meteo 有 archive API（archive-api.open-meteo.com，免费）→ 第二批可做
