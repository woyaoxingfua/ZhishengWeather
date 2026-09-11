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

**daily 可加**：sunrise, sunset, uv_index_max, daylight_duration ✅
（日出日落无需自算，API 直接给）

**hourly 可加**（本体 WeatherRepository 同款字段）：wind_gusts_10m, precipitation_probability, precipitation, surface_pressure, visibility, dew_point_2m, cloud_cover, uv_index ✅（原仓库 OpenMeteoApi.kt:43-46 同参数）

## 3. 结论

- 第一批（纯 Open-Meteo）：空气质量六项+AQI、分钟级 2h 降水、气压/能见度/露点/云量/阵风/UV、日出日落 → **全部零凭据可做**
- 气象预警：Open-Meteo 无此能力 → 需国内源（和风/彩云凭据），排第三批
- 生活指数：Open-Meteo 无现成，但 UV/温湿度/风速都有了 → 可本地计算（第二批）
- 历史天气/昨日对比：Open-Meteo 有 archive API（archive-api.open-meteo.com，免费）→ 第二批可做
