# 下一轮开场话术（直接复制粘贴用）

> 用法：新开一个会话，把下面 `====` 之间的整段话粘进去。它会先把交接文档读完再动手。
> 本文档本身也是交接物的一部分，位置：`ZhishengWeatherIOS/docs/handover/NEXT-SESSION-PROMPT.md`

====================================================================

继续开发 ZhishengWeather iOS 天气 App。

**第一件事：先完整读这份交接文档，读完再动手**
`C:\Users\Lenovo\WorkBuddy\2026-09-10-23-21-44\ZhishengWeatherIOS\docs\handover\HANDOVER-CURRENT.md`

里面 §0.5（用户原始诉求与项目沿革）、§0.6（需求演变轨迹，含**已作废需求**）、
§0.7（交付总账与**接线真相**）、§4（真机待修问题）是必读；
`docs/CI-pitfalls.md` 是编译与工具链陷阱的权威清单（已到 P-36），踩坑前先查它。

**项目硬约束（不要质疑，直接作为前提）**
- 仓库 `woyaoxingfua/ZhishengWeather`，分支 `ios`，本地路径
  `C:\Users\Lenovo\WorkBuddy\2026-09-10-23-21-44\ZhishengWeatherIOS`。
- **本机是 Windows，没有 Xcode / Swift，无法本地编译。唯一编译门禁是 GitHub Actions**
  （workflow 名 `iOS Build`）。**绝不许在没有 CI 结论的情况下声称代码能编译。**
- 分发方式是**侧载自用**（Feather + 购买的证书重签），不是上架。
- **App Group 共享容器在侧载产物上恒不可用**（entitlements 层面，买证书也改不了）
  → 需要共享容器的能力必须能优雅降级。**CI 全绿 ≠ 真机可用。**
- 运行环境就是**本机 Windows + 正常 Agent 工具链**（可开子代理）。不是 Linux 云电脑。

**开工顺序（这是用户 2026-10-08 明确裁定的主次）**
1. **先看 CI、先修 CI**。CI 红着的时候 `Archive`/`Package`/`Upload` 三个步骤全被跳过，
   **根本不会产出新 IPA** —— 真机验证无从谈起。所以 CI 优先于任何新功能。
   ⚠️ 本项目是"**修 A 暴露 B**"：编译器在一批失败后就不再往下编，所以**一轮通常只暴露一条错**。
   别期待一步到位，也别把每轮 failure 当成回归。
2. **接线，而不是加新功能**。§0.7.3 查出**四处「建了但没通电」**（编译过、测试过、
   但用户永远看不到）：卫星云图整条链（连 View 都没有）、河道流量源、WMO 天气现象映射、
   数据归属表。**先让已有的东西出现在界面上。**
   装配后**务必 grep 确认存在引用点** —— "CI 全绿但功能不存在"是本项目已知最坏的失败模式。
3. **再修用户报的真机问题**（§4）：小组件取不到 App 内当前位置的天气、实时活动无数据、
   版本号不变、重开 App 不恢复浏览位置。
4. 凡是 entitlements 相关的（小组件定位、实时活动、换图标），**必须真机验，CI 不算数**。

**关键操作命令（照抄，别自己试）**
- **推送必须走 PowerShell 通道**（Git Bash 里 `git push` 会被 SIGTERM 杀掉且无输出）：
  ```
  git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin ios
  ```
- 网络走代理 `http://127.0.0.1:7897`（端口可能变，先探 7897 / 2454 / 13489；直连有时也通）。
  curl 一律加 `--compressed`，否则看到乱码会误判。
- **查 GitHub API 会撞匿名限流**。取凭据：
  `printf 'protocol=https\nhost=github.com\n\n' | git credential fill`（取 `password=` 那行），
  再带 `-H "Authorization: Bearer <token>"` 请求。**不要把 token 落盘。**
- 取证顺序：`/actions/runs?per_page=N` 拿 run → `/actions/runs/{id}/jobs` 拿 **job id** →
  `/check-runs/{job_id}/annotations` 拿错误原文。
  ⚠️ 别用 `?branch=ios` 过滤（实测会返回 0 条）；注解里的 `** TEST FAILED **`
  **编译失败时也会打**，不能当"测试失败"的证据。
- 静态门禁 `bash qa-static-check.sh` **必须重定向落盘再读**（直接跑会被 SIGTERM）：
  `bash qa-static-check.sh > /tmp/qa.txt 2>&1`。它是静态检查，**与能否编译无关**。
- **不要动** `C:/Users/Lenovo/AppData/Local/Programs/WorkBuddy/resources/vendor/PortableGit/etc/gitconfig`
  里的 `[credential] helper` —— 那是"每次推送弹窗"的根治方案，看起来和默认不一样是**故意的**。

**共享 checkout 纪律（有多个写入方，出过事故）**
- 只准 `git add <明确路径>`；**严禁** `git add -A` / `git clean` / `git stash` /
  `git reset --hard` / rebase / force push。
- 提交前用 `git diff --cached --name-only` 核对暂存集**恰好**是本批文件；
  **暂存集为空 = 别人已替你提交了同样内容**，去 `git log` 找那个 commit。
- 多行提交信息写进 `.git/` 下的临时文件再 `git commit -F`（含中文引号时 `-m` 会被截断）。
- 判断状态**只看 `git show HEAD:<file>`**，不看工作区；判断是否已推送**只看远端**。
- **未推送的提交 = 从未被验证过**（本项目因此漏过一整轮编译错误）。
- ⚠️ **推送前先确认没有在跑的 CI**：GitHub 的 concurrency 组会**取消**同分支正在跑的运行，
  推一个 docs-only 提交会白白杀掉一次可能变绿的验证。

**关于"诊断脚本"的纪律（这条花了代价换来的）**
自己写静态扫描脚本去查问题时：
- **先拿"已知正确 + 已知错误"的样本验判据**，再扫全仓；
- 输出量级不对（本该几条却几百条）时**先怀疑判据，别怀疑代码**；
- **报出的每一条都要肉眼对着源码复核过再动手**。
反例：查"多行字符串缩进"第一版判据写错，把大段代码当成字符串内容，报出 160 条假警报
（真凶只有 7 条）；查"未处理 try"用宽松判据报出 44 条（真凶只有 1 条）。
**假警报比漏报更危险 —— 照它改会主动破坏好代码。**

**诚实纪律（本项目最重要的纪律）**
- 凡是写进提交信息 / 代码注释 / 文档 / worker brief 的具体数字，**必须来自当次实测**，
  并注明「实测」还是「文档如此，未实测」。
- **跨场景搬运结论前必须重新实测** —— 不能拿一个 API 的结论去证另一个 API。
- **API 的存在性与归属版本只能查官方文档，不能靠推理**。
  （已三例：`MKTileOverlay.loadingPolicy` 不存在、`MKMapPoint.mapRect(using:)` 不存在、
  `MKPolygon(center:radius:)` 其实是 `MKCircle` 的。）
- 不确定就写「无法确定」，**不许用"我没验证过所以……"当挡箭牌**，也不许假装做完了。
- 用户明确授权：**搞不定的能力可以诚实挂起并注明"希望有人可以指导"**，不必硬撑。

**关于用户（重要，别只看对话里的用户消息）**
- **用户的需求是不断变化的**，这是常态。请以 `HANDOVER-CURRENT.md` §0.6 的**演变轨迹**为准，
  特别注意「**已废弃**」那一节 —— 不要拿废弃目标当目标。
- **不要只看用户说了什么，也要看 agent 侧实际交付了什么**（§0.7 就是为此写的）。
- 用户风格：直接务实、要结论、不要客套；会自己换 API/模型，**别假设任何钥匙或端点长期有效**；
  要求"多开子代理、快速完成"时要**真并行**，不要串行等。
- 用户能接受的降级：做不出来的如实标注并说明卡在哪，**但不能悄悄少做**。

**当前状态（快照，务必自己用 `git log -1` 与 CI 查询复核）**

- 截至本文，HEAD 与远端 `origin/ios` 都在 `edac9a5`（另有本机新增的
  `NEXT-SESSION-PROMPT.md` 与文档更新待提交）。
- ✅ **里程碑：编译已经通过了。** 证据：`edac9a5` 那次 CI 跑了
  **9 分 25 秒**（03:45:46 → 03:55:11）；而此前每一轮编译失败都是 **1 分半**内就红。
  时间差本身就是"编过并在跑测试"的证据（**推断，但依据是实测的起止时间**）。
  且注解内容已从 `error: ...` 编译错变成
  `error: -[Suite testX] : failed: caught error: ...` / `XCTAssertNil failed` —— 这是**测试断言失败**。
- ❌ **现在的红灯是测试失败，不是编译失败。** 本轮 CI 报出 **10 条**，全部在 `NmcTyphoonTests`：
  - 9 条：`ResponseDecoding` 抛 `decodingDetail(path: "", debugDescription: "The given data was not valid JSON.")`
    —— 即送进 `JSONDecoder` 的字节不是合法 JSON。涉及
    `testEmptyListIsSuccessNotFailure` / `testEntryWithoutIDIsDropped` /
    `testForecastLeadCountIsNotFixed` / `testForecastLongitudeComesBeforeLatitude` /
    `testCoordinatesFallInMeasuredBasinRanges` / `testCoordinatesFallInMeasuredBasinRangesForHistoricalTyphoon` /
    `testHistoricalTyphoonToleratesNullForecastAndEmptyWindCircle` /
    `testActiveOnlyAndChineseNameTrimming` / `testEmptySecondaryNumberFallsBackToPrimary`。
  - 1 条：`testFutureYearIsRejectedWithoutRequest` — `XCTAssertNil failed:
    "https://typhoon.nmc.cn/weatherservice/jsons/list_2030" - 实测未来年份 404，前置拒绝（不发无谓请求）`。
- ⚠️ **这批红灯的根因【未确定】，下一轮请从"为什么 JSON 非法"入手排。**
  **有一条已排除**：`testEmptyListIsSuccessNotFailure` 用的是**行内单行字符串**
  `#"cb(({"typhoonList":[]}))"#`，**不在**本轮修缩进的那 7 个多行字符串里 ——
  所以**"缩进修复把字符串改坏了"不是这批红灯的解释**（至少不是全部）。
  更可能是**长期被编译失败遮蔽的老红灯**（本仓既有现象，见 `docs/CI-pitfalls.md` P-20）。
  排查建议：先单独看 `NmcTyphoonJSONP.strip()` 对这几个样本的**实际输出**，
  再对比 `NmcTyphoonResponse` 的 DTO 字段名。
- 本轮会话已连续修掉 **8 轮编译错误**（iOS 18 专属 API、保留字 `init`、编造的 MapKit API、
  变量遮蔽标准库函数、多行字符串缩进、`async throws` 顺序、`URLProtocol` 覆写加 `throws`、
  缺 `throws`）。**编译这条线已经走通，不要再在这里投入。**
- ⚠️ 一个仍然存在、CI 测不出的运行时嫌疑：台风地图三个覆盖层子类靠 `as? 子类` 分派，
  若 `MapKit` 的 convenience init 返回父类实例，则红/橙/黄三种覆盖层**全部不渲染**
  （需真机看台风卡）。见 `HANDOVER-CURRENT.md` §4.6。

====================================================================
