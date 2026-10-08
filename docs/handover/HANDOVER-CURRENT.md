# 交接文档 · 枳生天气 iOS（下一轮会话请先读完本页）

> 本文是给**下一个拿到本项目、对项目一无所知的 AI 会话（或人类维护者）**的自包含交接。
> 写法纪律：**结论先行、不客套、每个事实标来源**。
> 来源标签只有三种：`实测`（本轮亲自跑过 / 查过）/ `文档如此，未实测` / `据上一轮会话摘要`。
> **不确定一律写「无法确定」，绝不编造。** 本项目历史上连续多轮栽在"依据错了"上 ——
> 错误依据比错误结论更危险。
> 采集时间：**2026-10-08（UTC 约 02:49–02:52）**，全部数字都是那一刻的快照。

---

## 0. 30 秒速览

| 项 | 值 | 来源 |
|---|---|---|
| 仓库 | `woyaoxingfua/ZhishengWeather`，分支 **`ios`** | 实测 |
| 本地路径 | `C:\Users\Lenovo\WorkBuddy\2026-09-10-23-21-44\ZhishengWeatherIOS` | 实测 |
| 分发方式 | **侧载自用**（非 App Store），用户用 **Feather + 自购证书重签** | 据上一轮会话摘要 |
| 本地 HEAD | `9660e9d` | 实测 |
| 远端 `origin/ios` | `9660e9d` —— **本地与远端 0/0 同步**（无未推送提交） | 实测 |
| 最近一次 CI（`9660e9d`） | `iOS Build` 工作流，**进行中**，尚无结论 | 实测 |
| `6eefcb0` 的 CI 结论 | **failure**（编译失败）：`SevenTimerResponse.swift:61` 的 `let init: String?` —— `init` 是 Swift 保留字 | 实测（注解原文） |
| `7702ec4` 的 CI 结论 | **failure**（编译失败）：`WidgetCenter` 无 `currentConfigurations` 成员（iOS 18+ API） | 实测（注解原文） |
| 静态门禁 `qa-static-check.sh` | exit 0，**48 项 / PASS 47 / FAIL 0 / WARN 1** | 实测 |
| 数据源 | `SourceID` 枚举 **9 个 case**；`SourceCapability` **16 个 case** | 实测 |
| 卫星云图 | 批次 A 已提交，但**没有任何 View、也没接进 ContentView** → 死代码 | 实测 |

> ⚠️ **时间线说明（本文初稿写于 02:49–02:52，其后状态又变过，已回填）**
> **本文所有 SHA / 状态都是"那一刻的快照"，读到时请先用 `git log -1` 与 GitHub API 复核。**
> 初稿写成时是「`6eefcb0` 已推、CI 排队、结论未知」。其后每推一次就浮出下一条编译错：
> 1. `7702ec4` CI **failure** —— `WidgetCenter` 无 `currentConfigurations`（iOS 18+ API，见 P-23）
> 2. 修 → `6eefcb0` CI 仍 **failure** —— 暴露出 `SevenTimerResponse.swift` 的 `init` 保留字（P-25）
> 3. 修 → `9660e9d` CI **仍 failure** —— 暴露出 `TyphoonTrackMapView.swift` 三条编造 API（P-24）
> 4. 修 → `de13ec8` CI **仍 failure** —— 暴露出 `SatelliteCardModel.swift` 的**变量遮蔽**（P-32）
> 5. 修 → 见 `git log -1`（**本文未记录其 CI 结论**）
> → **"修 A 暴露 B"是本项目常态**（P-27）：一次只暴露一个文件的那条错，
> 所以每轮 CI 只能前进一格。**修完一条不要期待就绿了。**
> **读到本文时以当下实测为准，不要沿用本文快照。**

---

## 0.5 项目沿革与用户原始诉求（从 90 条用户原话还原，**本文件最不可省的一节**）

> **为什么单列这一节**：本项目**中途被中断过很多次**，每一轮交接都靠"上下文摘要"，
> 而摘要**有系统性遗漏**（只保留了最近十几条用户消息）。本节是从会话原始记录
> （`~/.workbuddy/projects/<项目目录>/*.jsonl`，本会话 49 MB / 9218 条）里
> **逐条还原的用户原话**，不是转述。
> **它解释了"为什么这个项目长成现在这样"** —— 缺了它，下一轮极可能做出与用户意图相反的决定。

### 0.5.1 项目定位的两次转变（最关键，先读这段）

1. **起点（2026-09）**：用户想在 Windows 上把 Android 开源项目 ZhishengWeather 重写成 iOS 版，
   编译走 GitHub Actions。原项目卖点是**三源融合（和风 / 小米 / Open-Meteo）**。
2. **第一次转变 —— 语言选型**：
   > 「不用上架，我自签就行……我只想在 iOS 上用，既然都重构，那 swift 行吗？」（U004）
   > 「objective c 呢？我其实**买的有开发者证书，是基本"全权限"的那种**，我也**眼馋小组件**，
   >   综合考虑下各个语言吧，你去做」（U005）
   → **小组件是用户的第一诉求，不是可选项。** Swift 胜出的现实理由是 WidgetKit 只能用 SwiftUI 写。
3. **第二次转变 —— 产品定位（**务必读懂，这是全项目的转折点**）**：
   > 「我本意是**借助小米的接口**，但是我意识到，安卓平台能用小米接口好像是安卓本来就能用小米的天气，
   >   但是 **iOS 是不行啊**，所以我感觉这个项目做下去**偏离本意**了，既然这样就把它做成一个
   >   **尽情调用 api 的天气**吧，可以参考原项目，你看着办。」（U033）
   → **"复刻小米天气"这个目标已被用户本人放弃。** 现在的定位是**通用多源天气 App**。
   这解释了为什么后续大量工作都在"找免费数据源 / 接更多源"上 ——
   **那是用户主动改的方向，不是 agent 跑偏。** 下一轮不要试图把它拉回"复刻原版"。

### 0.5.2 用户的硬性偏好与禁令（会被反复问到）

- **禁止使用 AI 生图付费服务**：
  > 「你要是画图的话**尽量别用 hyimage**，这玩意**一张太贵了**，你要是想用的话我可以给你
  >   **免费的魔搭额度**」（U043）
  → 需要插图时**先问用户**，或只用免额度渠道。这条历史上被违反过，用户是专门提的。
- **不在意 token 消耗，但要速度；允许大量并行**：
  > 「我换成我自己买的 api 的模型来，这样不会限额了，**放开跑**，要成果，**我不在意消耗**，
  >   如果你能管理过来**甚至可以弄几十个子代理**」（U057）
- **全权授权**（但"全权"不等于可以走偏）：
  > 「可以，**我全权交给你了**，还有我目前是**自用**」（U074）
  > 「你继续吧，**你全权弄**，我其实已经没有 idea 了，就看你了，**头脑风暴**吧」（U034）
  > 「做，**我不说停你就别停**」（U073）
- **允许诚实降级 —— 授权你把搞不定的东西挂起来**（重要）：
  > 「要不你再学学别人做的，**实在不行就先不弄**（移到最下面，写上**希望有人可以指导**）
  >   （或者等我有了 mac 真机调试），就补全功能和数据」（U066）
  → 即：**搞不定的能力可以诚实挂起并注明"求指导"，不必硬撑、更不许假装做完了。**
  这与本仓的诚实纪律天然一致。
- **README 是写给外人的**：
  > 「readme 是**写给外人看的**，你这不对吧」（U060）
- **用户会自己换 API / 换模型 —— 不要把任何钥匙或端点当长期有效**：
  > 「之前是我自己配置的 api，**速度限额了**，现在我更换了」（U029）
  > 「哎，我又换 api 了，这次继续干吧，放心大胆的」（U037）
- **数据源要"尽可能全"**：
  > 「数据源还是那句话，我希望**有免费使用额度的也可以加上**……总之就是**学习优秀的产品**」（U066）
  > 「反正我就要**尽可能的全**……就是一直开发，多开点子代理，快」（U073）

### 0.5.3 曾考虑过、但**没走**的路线（别重复提议；除非用户重新提起）

- **xtool**（在 Windows 上交叉编译 iOS，用户认为它能做小组件）：
  > 「我可是听说 **xtool 可以做到小组件开发**啊」（U017）
  本仓最终仍以 **GitHub Actions 为唯一编译门禁**。**若想复活这条路，先问用户。**
- **迁到 Linux 云电脑开发**：
  > 「我马上不能在 win 上写了，电脑要收起来了，我需要**换到豆包的云电脑上（Linux 的）**，
  >   请你写好交接文档，并且**豆包默认没有专家团**，所以你最好写清楚点，具体怎么做，开发怎么办，
  >   就是**事无巨细**」（U016）
  → 仓库里 **`docs/handover/HANDOVER-linux-migration.md` 就是为这个场景写的**，不是废纸。
  → **下一轮开工前先确认运行环境**：还是 Windows + 专家团？还是 Linux 云电脑、没有子代理？
  两种环境下"该怎么做"差别很大（云电脑上没有 Agent 工具时，所有验证只能靠人手动做）。

### 0.5.4 用户报过、但容易在交接中被漏掉的具体症状

（与 §4「当前待修」互补；这些是**历史原话**，部分可能至今未解）

| 用户原话（节选） | 出处 | 备注 |
|---|---|---|
| 「真机都获取不到数据，**一直提示格式问题**」 | U028 | 疑似解码 / 字段格式问题。**§4 里没有这一条**，值得单列排查 |
| 「图标好像不能更换，这个好像是**证书的问题**？反正就是 app 不能主动换图标，但是**可以在签名时更换**」 | U043 | **用户自己的诊断**，与本仓 `setAlternateIconName` 在侧载下失败一致。**换图标在侧载产物上先天受限** |
| 「切换图标的诊断是对的但是**在一瞬间会报错**然后不成功」 | U052 | 诊断层已生效，失败发生在系统调用瞬间 |
| 「小组件**为啥不跟着我主 app 里当前的地区**啊？非局限城市？」 | U045 | §4.1 的**原始表述** |
| 「**完全没变化**，该是不能用的话是不能，和上次报错就一样」 | U054 | 反复确认"改完没变化" —— 与 §4.3「根本没产出新包」互为印证 |
| 「一是**版本号没更新**导致我甚至怀疑我都没安装」 | U066 | §4.3 的最早出处 |
| 「**加点 iOS 系统特有的功能，比如 spotlight 或者其他之类的**」 | U050 | Spotlight 已做；仍有可加空间 |
| 「这个 ipa 我试了下，一般，确实是 mvp，就是和 **fork 的本体基本没什么联系**」 | U011 | 早期评价。提醒：**"贴近原项目"曾是用户期待，但已被 U033 推翻** |

### 0.5.5 会话记录在哪（下一轮自己去核，别只信摘要）

```
~/.workbuddy/projects/c-Users-Lenovo-WorkBuddy-2026-09-10-23-21-44/
  ed607fcc-0667-44ac-9b78-b90aa5c9657e.jsonl   ← 主会话全文（本次 49 MB / 9218 行）
  ed607fcc-0667-44ac-9b78-b90aa5c9657e/         ← 子代理各自的 jsonl
```

**提取方法（可直接复用）**：jsonl 每行一个 JSON，字段 `type` 取 `message` / `function_call` /
`function_call_result` / `reasoning`；只看 `type=message & role=user` 即为用户消息。
⚠️ **坑：用户消息的 `content` 是数组，第一块常是 `<system-reminder>`，你的原话在后面的块里** ——
必须先**删除** system-reminder 块再取 `<user_query>`，**不能因为开头是 `<` 就整条丢掉**
（我第一次就是这么干的，把 90 条真实消息滤成了 16 条）。

---

## 1. 硬约束与环境（最重要，先看这段）

### 1.1 唯一编译门禁是 GitHub Actions
- 本机 **Windows，无 Xcode、无 Swift、无 iOS SDK**（实测环境）。
- 唯一编译门禁：GitHub Actions 工作流 **名字就叫 `iOS Build`**（文件 `.github/workflows/ios.yml`）。
  runner `macos-14`、Xcode 锁定 **15.4**、XcodeGen 锁定 **2.42.0**（见 §5 P-01）。
- **绝对不许在没有 CI 结论的情况下声称代码能编译。** 本地静态检查、读代码、单元逻辑推演
  **都不是**编译证据。本项目历史上多次"看起来对、CI 一跑就崩"。

### 1.2 CI 全绿 ≠ 真机可用（结构性，不是 bug）
- 侧载（Feather + 自购证书重签）下，**App Group 共享容器恒不可用** —— 这是 **entitlements 层面**的
  事实：重签工具会丢弃 entitlements，`group.com.zhisheng.weather` 从不生效，主 App 与 Widget
  各拿一个互相隔离的沙盒（`docs/CI-pitfalls.md` P-19 `文档如此`）。
- **买证书本身改不了这一点** —— 只有当重签工具**保留 entitlements** 时才可能恢复（P-19 提到的
  SideStore / AltStore 是理论出路）。当前分发渠道（Feather 重签）未走这条路。
- 因此 Widget 的架构早已改为 **「自力取数」**：不依赖共享容器也能自己联网取数。
  权威设计文档：`docs/handover/ARCH-zhisheng-ios-widget-selfsufficiency.md`，核心代码在
  `Core/Logic/WidgetEntryResolution.swift`（两条正交阶梯：城市阶梯 C0/C1/C2、数据阶梯 L0/L1/L2）。
- ⚠️ 凡是靠 entitlements 才生效的能力（App Group / 推送 / associated domains / Widget 定位资格），
  **CI 绿不能作为真机可用的证据**。

### 1.3 网络与代理
- 本机需走代理。查 GitHub API 用：
  `curl -s -m 25 --compressed -x http://127.0.0.1:7897 <url>`（实测可用）。
  直接不带代理时，环境变量里的 `HTTPS_PROXY=http://127.0.0.1:5007` 也能通（实测可用）。
- ⚠️ **代理会间歇性抽风**（返回空体 / `HTTP:000` / SSL 中断）。**所有 curl 都要套重试循环 +
  结果校验**，裸调必踩（P-15）。本轮就碰到了：同一条命令第一次 `HTTP:000`、重试后 `200`。
- ⚠️ **GitHub API 的 `?branch=ios` 过滤本轮实测返回 `total_count: 0`**（明明有 149 次 ios 分支
  运行）；改用不带 `branch` 的 `?per_page=N` 查询才拿到数据，结果里 `head_branch` 确实是 `ios`。
  这是本轮实测到的 API 怪象，**原因未查明**，照做即可（别用 branch 过滤）。

### 1.4 git push 必须走 PowerShell 通道
- 在 Bash（Git Bash）里 `git push` **反复被 SIGTERM 杀掉且无输出**（据上一轮会话摘要 + 本轮
  文档一致），push 请走 **PowerShell 通道**，并带代理：
  `git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 push origin ios`
- P-14/P-15 记录：401 后 helper 会挂死；GH007 要求 commit 邮箱用
  `166398578+woyaoxingfua@users.noreply.github.com`（`文档如此`）。

### 1.5 ⚠️ 一个已修复、**绝不可撤销**的环境改动
- 文件：`C:/Users/Lenovo/AppData/Local/Programs/WorkBuddy/resources/vendor/PortableGit/etc/gitconfig`
- 其中 `[credential] helper` 已被**改成直指 `git-credential-manager.exe`**（删掉了会弹窗的
  `helper-selector`）。这是用户投诉"每次推送都弹窗"的**根治方案**。
- **新会话不要去"修复"或还原这个配置。** 看到它"和默认不一样"是**故意的**。

---

## 2. 当前代码状态（全部实测）

### 2.1 指针与工作区
- `git status --porcelain` → **干净**（本轮实测）。曾出现的未跟踪目录 `.ci-tmp/` 是 team-lead 放 CI 取证
  临时文件用的，已写进 `.git/info/exclude`（**本地排除，不入库**），故不再出现在 status 里。
- 本地 HEAD = `origin/ios` = **`6eefcb0`**，`git rev-list --left-right --count origin/ios...HEAD`
  → `0 0`（**完全同步，没有未推送提交**）。
- 最近提交（`git log --oneline -15`，实测）：
  ```
  6eefcb0 fix(ci): WidgetCenter.currentConfigurations 是 iOS 18+，改用 iOS 14+ 完成回调版
  f1478e4 feat(fallback): 接入第八源 7timer! 作为字段级兜底源
  7702ec4 fix: TyphoonTrackMapView 缺 import SwiftUI（CI 编译失败）
  c703895 docs: 独立核查第三方《天气API开发接入指南》并产出选型对照表
  76993aa refactor(satellite): 判定收敛到单一路径 + 去重复字节层 + 显式注入实参
  9048ee0 feat(satellite): 卫星云图批次A —— 纯黑判定真正接入取数链路 + 30 个测试
  017230b fix: Logger 消息参数是 OSLogMessage，不能直接传运行时 String（CI 编译失败）
  ...
  ```

### 2.2 CI 结论（`actions/runs` 实测）
- 仓库累计 **149 次运行**（实测）。
- 最近 10 次（`iOS Build`，均 `push` 事件，均 `head_branch=ios`）：

  | 时间(UTC) | head | 状态 | 标题 |
  |---|---|---|---|
  | 2026-10-08 02:49 | `6eefcb0` | **queued** | fix(ci): WidgetCenter.currentConfigurations 是 iOS 18+… |
  | 2026-10-08 01:21 | `7702ec4` | **failure** | fix: TyphoonTrackMapView 缺 import SwiftUI |
  | 2026-10-07 15:43 | `c703895` | failure | docs: 独立核查第三方《天气API开发接入指南》… |
  | 2026-10-07 14:34 | `017230b` | failure | fix: Logger 消息参数是 OSLogMessage… |
  | 2026-10-07 11:52 | `4b4d439` | failure | feat(tide): 接入 Open-Meteo 潮汐 |
  | 2026-10-07 10:53 | `eb1e332` | failure | docs: 实测调研雷电/海洋/潮汐/卫星云图/花粉 |
  | 2026-10-07 10:35 | `9402432` | failure | test(typhoon): 修台风批次 8 个红灯… |
  | 2026-10-07 09:44 | `c707968` | failure | feat(typhoon): 接入中央气象台台风网 |
  | 2026-10-07 08:51 | `cc1b514` | failure | feat(widget): 打开小组件时间线的可诊断性黑盒 |
  | 2026-10-07 08:20 | `dce9875` | **success** | docs(CI): 补 P-20~P-22（拆 step 方案） |

  → **自 `dce9875` 之后连续 8 次 completed 运行全部 failure**，最近一次成功已是前一天。
- `7702ec4` 的**失败根因（注解原文，实测）**：
  ```
  error: value of type 'WidgetCenter' has no member 'currentConfigurations'
  （AppDiagnosticsStore.swift，失败 step = "Run unit tests (simulator)"，exit code 65）
  ```
  这是**编译失败**（不是测试断言失败）。而**该 step 同时承担编译与测试**（见 §5 P-20、P-22），
  所以这次 CI **一个测试都没跑**——"编译失败遮蔽测试红灯"的老问题仍然存在，
  **workflow 至今未按 P-22 方案 A 拆 step**（本轮读 `.github/workflows/ios.yml` 确认）。
- `6eefcb0` 是针对上面这条编译错的修复：改走 iOS 14+ 的完成回调版
  `WidgetCenter.getCurrentConfigurations(_:)`，用 `withCheckedThrowingContinuation` 桥接成 async，
  新增 `loadCurrentWidgetConfigurations()` 承载说明。
  **实测结论：CI 仍 failure —— 但那笔修复本身有效**（`WidgetCenter` 那条错已消失），
  它把**下一个**编译错暴露了出来（注解原文）：
  ```
  Core/Networking/SevenTimerResponse.swift:61:9: error: property declaration does not bind any variables
  Core/Networking/SevenTimerResponse.swift:61:9: error: keyword 'init' cannot be used as an identifier here
  ```
  原因：7timer! 的 JSON 键就叫 `"init"`（模型初始化时刻），而 `init` 是 Swift 保留字。
  **这是该文件第一次进入编译门禁** —— 7Timer 那一提交（`f1478e4`）此前一直躺在本地未推送。
  教训：**「没推过的代码等于没被验证过」**。
- `9660e9d` 是上述错误的修复：属性改名 `initTime` + 新增显式 `private enum CodingKeys`
  把 `initTime` 映射回 JSON 键 `"init"`（**对外 JSON 契约一字未变**），mapper 读取处同步改。
  为什么不用反引号 `` let `init` ``：就算写得出来，读取处 `response.init` 也会被解析成
  「引用构造器」而非「取属性」—— 改名 + 显式键映射是唯一干净的路。
  **不要假设它能过 CI** —— 本项目"修 A 暴露 B"是常态（P-20）。

### 2.3 静态门禁
- `qa-static-check.sh`：**exit 0**，`汇总：总计 48 项，PASS 47，FAIL 0，WARN 1`（另有 INFO 100 条）。
- 唯一 WARN：`SC-42c`「App 侧尚无凭据存储实现 —— 若本轮仍不接入需 Key 的源可忽略」
  （即**目前没有接入任何需 Key 的源**，这是正常的，不是缺陷）。
- 该脚本报的测试规模：**测试文件 100 个 / 测试用例 1339 条**（`SC-29` / `SC-30`）。
- ⚠️ **它只是静态检查，与能否编译无关，不能当编译证据。**

---

## 3. 已接入的数据源清单（实测，以代码为准）

架构：**可插拔多源 + 字段级兜底**。三段式 = **Endpoint（发出请求）/ Mapper（解析成字段）/ Providing（对外提供）**，
字段级合并与兜底在 `Core/Logic/FieldFallbackResolver.swift` 与 `FieldPatch`。
源的静态元信息**唯一真源**是 `Core/Logic/SourceDescriptor.swift` 的 `SourceDirectory.all`。

`SourceID`（`Core/Networking/SourceID.swift`）**9 个**（`实测` `grep -c 'case ... = '` = 9）：

| # | SourceID | rawValue | 能力（`capabilities`） | 凭证 | 参与自动摘除 |
|---|---|---|---|---|---|
| 主 | `openMeteoForecast` | `open-meteo-forecast` | currentObservation / hourlyForecast / dailyForecast / minutelyPrecipitation | 免 Key | 否（主源只记录不摘除） |
| — | `openMeteoAirQuality` | `open-meteo-air-quality` | airQuality | 免 Key | 否 |
| 二 | `sunriseSunset` | `sunrise-sunset` | solarEvents | 免 Key | 是 |
| 三 | `metNorwayForecast` | `met-norway-forecast` | basicNumericFields | 免 Key | 是 |
| 四 | `marineForecast` | `open-meteo-marine` | marineWaveConditions / marineTide | 免 Key | 否 |
| 五 | `floodForecast` | `open-meteo-flood` | riverDischarge | 免 Key | 否 |
| 六 | `nmcAlarm` | `nmc-alarm` | officialWarning | 免 Key | 否 |
| 七 | `nmcTyphoon` | `nmc-typhoon` | typhoonTrack | 免 Key | 否 |
| 八 | `sevenTimer` | `7timer` | coarseFallbackFields | 免 Key | 是 |

- `SourceCapability`（`Core/Logic/SourceCapability.swift`）共 **16 个 case**（实测）。
- 命名口径：`rawValue` 必须**与实际域名/服务语义一致**（例：marine/flood 是**独立子域名**
  `marine-api.` / `flood-api.`，写主站一律 404 —— 见 `SourceID.swift` 内注释）。
- **「无 EV-1 信号源」是已知现状**：air / marine / flood / nmcAlarm / nmcTyphoon 的领域模型
  （空气质量 / 浪 / 流量 / 预警 / 台风）**不在 `WeatherFieldKey` 域内**，故 `requiredFields: []`
  **诚实留空**，同时 `participatesInAutoExclusion: false`（不给设置页一个"点了没反应"的开关）。
  接线后再改 `true`（`SourceDescriptor` 注释明写）。
- 关键文件：`Core/Networking/SourceID.swift`、`Core/Logic/SourceCapability.swift`、
  `Core/Logic/SourceDescriptor.swift`、`Core/Logic/FieldSourceRegistry.swift`、
  `Core/Logic/FieldFallbackResolver.swift`（及各源 `*Endpoint.swift` / `*Mapper.swift`）。
- 守卫测试：`ZhishengWeatherTests/SourceDirectoryCoverageTests.swift` 断言
  `Set(SourceID.allCases) == Set(SourceCatalog.all.map(\.id))`（防漏登记 + 防幽灵条目）。

---

## 4. 用户报的真机问题（**下一轮主线**，逐条带状态）

> 这些是**用户在真机上看到的**，CI 全绿也照样存在。状态标签：未开始 / 部分完成 / 阻塞。

### 4.1 小组件能显示"默认地址"的天气，但**拿不到 App 内"当前位置"的天气** —— 部分完成
- 现状（读码事实）：「当前位置」整条链路**已实现**：
  - Core 纯判定：`Core/Logic/WidgetLocation.swift`（`WidgetLocationOutcome` 三态：
    `located` / `notAuthorized` / `unavailable`）、`Core/Logic/WidgetEntryResolution.swift`
    （`WidgetEmptyReason.locationNotAuthorized` 与 `.locationUnavailable` **两态分开**）。
  - Widget 侧取点器：`ZhishengWeatherWidget/WidgetLocationService.swift`（`CLLocationManager` 外壳）。
  - 设备 plist：`Config/ZhishengWeatherWidget-Info.plist` 有 `NSWidgetWantsLocation`
    （实测存在）；主 plist 有 `NSLocationWhenInUseUsageDescription`。
  - 产物级测试：`ZhishengWeatherTests/WidgetLocationBuildProductTests.swift`。
- **"默认地址能显示"** 说明小组件**自力取数（L1）这条链路是通的**（得力于 §1.2 的 self-sufficiency 改造）。
- **"当前位置拿不到"** 的**根因本轮无法确定**（无真机）。代码里的**第一嫌疑**是资格判据：
  Apple 明文要求 `CLLocationManager.isAuthorizedForWidgetUpdates == true` 才给小组件定位，
  且小组件扩展**不能自己弹授权窗**（授权由宿主 App + 系统"添加组件"问句完成）。
  侧载场景下这条资格极易为 false → 真机会落到 `.locationNotAuthorized` 空态。
  **这是推断，未在真机验证 —— 下一轮请优先用真机确认落在哪个 `WidgetEmptyReason`。**
  （注意：Apple 明文说"已获资格但本轮没取到"是**常态**，所以 `.locationUnavailable` 也会常出现，
  两者**必须区分**，别合并提示。）

### 4.2 实时活动（Live Activity）没有数据 —— 部分完成
- 现状（读码事实）：整条链路**已实现并接线**：
  - 领域模型 / 内容：`Core/Logic/WeatherActivityAttributes.swift`、
    `ZhishengWeather/WeatherActivityContentBuilder.swift`。
  - 管理：`ZhishengWeather/WeatherActivityManager.swift`（能力探测 + 开关 + 手动启停），
    已注入 `WeatherViewModel`（`activityManager`）与 `ZhishengWeatherApp`（`@State activityManager`）。
  - 渲染扩展：`ZhishengWeatherWidget/WeatherLiveActivity.swift`（nil 字段如实渲染「—」/「暂无数据」）。
  - 开关持久化：`ZhishengWeather/LiveActivitySettings.swift`（App 本地 UserDefaults，**不进**共享容器）。
  - 测试：`WeatherActivityContentBuilderTests` / `WeatherActivityManagerSeedingTests`。
- **真机"没有数据"的根因本轮无法确定**。可能方向（**均未验证**）：活动被手动启动后
  没有随取数成功被更新（`WeatherViewModel` 里"取数成功 → 更新实时活动"的接线点）、
  或 `ActivityKit` 能力在侧载产物上受限、或活动根本没被成功启动。
  **下一轮请先在真机确认"活动是否被启动了"（系统锁屏/灵动岛是否出现卡片），再分叉排因。**

### 4.3 App 版本号没变（用户看不到版本更新）—— 根因已定位（高可信推断）
- 版本真源：`project.yml` → `MARKETING_VERSION: "0.1.0"`、`CURRENT_PROJECT_VERSION: "1"`（实测）。
- **CI 的 Archive 步骤会注入构建号**：`.github/workflows/ios.yml` 的 `Archive (unsigned)` 里
  `CURRENT_PROJECT_VERSION="${{ github.run_number }}"`（实测，逐次递增）。
  设置页按 `版本号 (构建号)` 两段显示（`SettingsView`，读 `CFBundleShortVersionString` + `CFBundleVersion`）。
- ⚠️ **关键因果链（实测证据 + 强推断）**：`.github/workflows/ios.yml` 里
  `Run unit tests (simulator)` → 失败则后面的 **`Archive` / `Package unsigned IPA` / `Upload unsigned IPA`
  全部 `skipped`**（本轮读 `7702ec4` 那次运行的 step 结论，实测这三个 step 都是 skipped）。
  → 由于 §2.2 中自 `dce9875`（约 18 小时前、最后一次成功）之后的**所有运行都失败在测试 step**，
  这些运行的 Archive/Package/Upload **全被跳过**——**期间没有产出过任何新的 IPA 产物**。
  → 用户手里能装的仍是最新的可用旧包，自然"版本号没变"。
- 因此：**要修"版本号"，先修 CI 编译**（`6eefcb0` 正在排队）。另外 `MARKETING_VERSION` 恒为
  `0.1.0`，用户若只看短版本号永远不变，需看括号里的构建号（`github.run_number`）。
  （因果链的"没产出新 IPA"是直接实测；"用户因此装了旧包"是推断。）

### 4.4 重开 App 回到主页，不恢复上次浏览位置 —— 部分完成（缺失明确）
- 现状（实测）：App 侧**完全没有**导航状态持久化 —— grep `ZhishengWeather/` 无任何 `@SceneStorage` /
  相关 `@AppStorage` 持久化；`ContentView` 里导航是 `@State private var navigation: NavigationPath`
  （纯内存，进程一退即丢）。路由真源是 `ZhishengWeather/AppRouter.swift`（含冷启动 `pendingRoute`）。
- 结论：**"恢复上次位置"这一能力目前不存在**（不是坏，是没做）。下一轮要新增持久化层。
  ⚠️ 注意 `AppRouter` 已有"单调令牌 + pendingRoute"的冷启动路由机制，接入持久化时**别与之打架**。

### 4.5 卫星云图：批次 A 已提交但**没接进界面（死代码）** —— 未开始（批次 B/C）
- 批次 A 提交：`9048ee0 feat(satellite): 卫星云图批次A…`（纯黑判定 + 30 个测试）。
- **实测核查结果（这是本轮重点核实的）**：
  - 存在的类型：`ZhishengWeather/SatelliteCardModel.swift`（`@MainActor @Observable` 的**状态容器**，
    **不是 View**）；`Core/Networking/SatelliteImageService.swift`（actor）、
    `SatelliteFrameValidator.swift`、`SatelliteImageEndpoint.swift`、`RainViewerService.swift`。
  - **没有任何 `struct ...: View` 形式的卫星云图视图**（`grep 'struct .*Satellite.*: View'` = 0 命中）。
  - **`SatelliteCardModel` 全仓无任何引用点**（除自身与 `SatelliteFrameValidator` 的注释）：
    `ContentView` 无 `Satellite` 字样，也没有任何渲染路径持有它。
  - → **结论：卫星云图是死代码。CI 全绿（编译通过 + 测试通过）也改变不了它"不存在于 App 界面"
    这个事实。** 这正是本项目已知的最坏状态（"CI 全绿但功能不存在"）。
- 下一轮：写批次 B（View，参考 `RadarCardModel` / `TyphoonCardModel` 同款"独立链路 + 独立失败域 +
  `@State` 持有"模式）与批次 C（装配进 `ContentView` + 确认引用）。**装配后务必核实
  "确实有引用点"，不要只看代码存在。**

---

### 4.6 台风地图：编译已修，但有一个 **CI 抓不到的运行时嫌疑** —— 待真机验
- 本文件（`ZhishengWeather/TyphoonTrackMapView.swift`）在 `9660e9d` 之后一轮被修掉三条编译错：
  - `MKMapPoint(coord).mapRect(using: .longitudeLatitude)` → 改用
    `MKMapRect(origin: MKMapPoint, size: MKMapSize(width:height:))` + `union(_:)`（三个 API 已逐个核对官方文档）。
  - `TyphoonWindCirclePolygon(center:radius:)` → `MKPolygon` 没有这个初始化器（那是 `MKCircle` 的），
    改为自家算 64 边形顶点后走 `init(coordinates:count:)`。
- ⚠️ **未验证的运行时嫌疑（CI 永远测不出，必须真机看）**：三个覆盖层子类
  （`TyphoonRealTrackPolyline` / `TyphoonForecastPolyline` / `TyphoonWindCirclePolygon`）
  都是「**空子类 + 继承父类 convenience init**」，而 `Coordinator.rendererFor` 靠
  `overlay as? 子类` 分派。**若 MapKit 的 convenience init 内部返回的是父类实例
  （而非 `self` 所在子类），子类身份就会丢失** → 三个 `as?` 全部失败 →
  地图上只剩空白底图（且**不报任何错**）。
- **判定方法（下一轮优先做）**：真机上打开台风卡，看有没有**红线 / 橙虚线 / 黄圈**。
  有 → 子类身份保住了。全无 → 就是这个坑，届时把「子类分派」换成显式包装类型
  （例如自定义 `MKOverlay` 包装 + `title` 之外的显式标记），不要再赌子类继承。
- **诚实标注**：以上因果是**推断**，`MapKit` 子类继承行为本轮**未实测**。

---

## 5. Swift 编译陷阱清单（本项目血泪，权威版在 `docs/CI-pitfalls.md`）

> 下面 P-01..P-22 是 `docs/CI-pitfalls.md` 的**摘要**（原文更详细，含实测证据表，建议需要时回读）。
> 编号保留以便追溯。末尾 **P-23..P-31 是本轮新增**的。

- **P-01** XcodeGen 锁 **2.42.0**，**禁止 `brew install xcodegen`**（brew 新版产出 Xcode 26 工程格式，
  被 Xcode 15.4 拒读）。
- **P-02** `set -o pipefail` 下 `grep | head -n1` 触发 SIGPIPE 141 判失败 → 用 `grep -Eom1`。
- **P-03** 产物上传用 `if-no-files-found: error`（`ignore` 会静默吞问题）。
- **P-04** 默认参数在**调用方**的非隔离上下文求值 → `@MainActor` 类型的默认参数要改成 `nil` + 体内创建。
- **P-05** `struct XxxApp: App` 整体标 `@MainActor`。
- **P-06** **项目铁律：所有 View 结构体整体标 `@MainActor`**（`init` / 计算属性不自动隔离）。
- **P-07** 属性与方法同名 = `invalid redeclaration`；副作用方法用动词前缀。
- **P-08** AppIntents `@Parameter default:` 必须编译期字面量。
- **P-09** 带 `accuracy:` 的断言不收可选，先 `try XCTUnwrap`。
- **P-10** 单参闭包必须显式忽略参数：`map { _ in ... }`。
- **P-11** 实参顺序要对齐签名。
- **P-12** 竞态单测必须让首请求真正起飞（先让出主线程）。
- **P-13** 业务规则冲突要回归文档裁定，文档要写**优先级顺序**。
- **P-14** push 卡 credential helper → 本轮统一走 PowerShell 通道（见 §1.4）。
- **P-15** 代理与网络：本机直连 GitHub 不通；代理间歇抽风 → **所有 curl 套重试**。
- **P-16** Windows Python **读不了 Git Bash 的 `/tmp`** → 临时文件放**工作目录**。
- **P-17** `[T?]?` 的元素访问是**双层可选**，`?.first?.member` 会断 → 显式解包或走助手。
- **P-18**（代价最高）**单测 Stub 与实现共享同一套假设 → 真机缺陷必然逃逸**。
  对第三方 API 行为的断言必须用**真实响应**验证过。
- **P-19** 未签名 IPA 的 App Group 失效（见 §1.2）。
- **P-20** **单一 step 同时承担编译与测试 → 编译失败时测试根本没跑**（不是"绿"，是"从未被检验"）。
  ⚠️ 本项目**至今未实现** P-22 方案 A（拆 step），此缺陷**仍在**。
- **P-21** 取证 API 坑：`check-runs/{id}/annotations` 的 `{id}` 是 **job id** 不是 run id；
  报错响应是 **HTTP 200**，判空必须判 `message == "Not Found"`；annotations 返回**裸数组**。
- **P-22** 拆 step 方案 A（`build-for-testing` + `test-without-building`）+ D（注解区分失败类别）
  为推荐组合；**原文明确标注 YAML 均未实测**。

**本轮新增（P-23..P-31）—— ⚠️ 权威正文已写进 `docs/CI-pitfalls.md`，此处只给一行索引：**

- **P-23** 可用性门槛不够时，编译器报的是**「无此成员」而不是「版本太新」** ——
  `WidgetCenter.currentConfigurations()` 是 iOS 18+，部署目标 17.0 → 极易被误判成「拼错了名字」。
  正解：iOS 14+ 完成回调版 `getCurrentConfigurations(_:)` + `withCheckedThrowingContinuation`（`6eefcb0`）。
- **P-24** **编造 API** 是反复发作的独立错误类，**MapKit 已三例**：
  `MKTileOverlay.loadingPolicy`（不存在）、`MKMapPoint.mapRect(using:)` 与 `.longitudeLatitude`（都不存在）、
  `MKPolygon(center:radius:sides:)`（不存在 —— 那是 **`MKCircle`** 的初始化器）。
  → **API 的存在性与归属版本只能查官方文档，不能靠推理。**
- **P-25** **保留字不能当属性名，反引号也救不了**。7timer 的 JSON 键叫 `"init"` →
  改名 `initTime` + 显式 `CodingKeys` 映射回 `"init"`（`9660e9d`）。
  → **DTO 字段名不能照着 JSON 键直接抄成 Swift 属性名。**
- **P-26** **未推送的提交 = 从未被验证过**（`f1478e4` 一推就炸出 P-25）。
- **P-27** **一轮 CI 通常只暴露一条编译错**（"修 A 暴露 B"是常态）；
  且注解步骤还截前 40 行，所以「注解条数」**不是**错误总数。
- **P-28** **测试 step 失败 → `Archive` / `Package` / `Upload` 全部 skipped → 不产出 IPA**。
  这与用户报的「版本号没变」直接相关（见 §4.3）。
- **P-29** `Logger` 的消息参数必须是 `OSLogMessage`（不能传运行时 `String`）。
- **P-30** 新建 `.swift` 容易漏 `import SwiftUI` / `import UIKit`（一次漏 import = 6 条 `cannot find type 'View'`）。
- **P-31** 本地无编译器时，「参考周围代码但没核实」是一类**独立**错误：
  **引用的每个 API 都要先核实存在**（曾写出根本不存在的 `makeForTesting`）。
- **P-32** 局部变量**遮蔽标准库函数**：`let stride = 4` 会让 `stride(from:to:by:)` 变成
  「调用 `Int`」，报 `cannot call value of non-function type`（**错误信息里完全不提遮蔽**）。
  正解是**改局部变量名**，不是写 `Swift.stride(...)`。
  高危名字：`stride` / `min` / `max` / `abs` / `count` / `first` / `last` / `map` / `filter`。

---

## 6. 静态门禁与操作纪律

### 6.1 跑 `qa-static-check.sh` 的正确姿势
- 在 Bash 里**直接跑会被 SIGTERM 杀掉且无输出**。必须**重定向落盘**再读：
  ```bash
  bash qa-static-check.sh > .ci-tmp/qa.txt 2>&1   # 然后 Read .ci-tmp/qa.txt
  ```
- 本轮实测：**exit 0，48 项 / PASS 47 / FAIL 0 / WARN 1**（WARN = `SC-42c`）。
  运行耗时约 **2 分钟**，建议 `run_in_background`。
- ⚠️ 它是**静态检查**，**与能否编译无关**，别当编译证据。

### 6.2 共享 checkout 纪律（**多会话/多 worker 同时写入，硬要求**）
> 本轮亲身经历：写这份文档期间，远端指针从 `7702ec4` 变到 `6eefcb0`、工作区状态从"有未推送提交"
> 变成"0/0 同步"——**仓库是共享的，随时有人在写**。所以：
- 只准 `git add <明确路径>`；**禁止** `git add -A` / `git clean` / `git stash` /
  `git reset --hard` / rebase / force push。
- 提交前用 `git diff --cached --name-only` 核对暂存集**恰好**是本批文件。
  **若暂存集为空 = 别人已替你提交了同样内容** → 去 `git log` 找那个 commit，**别重复提交**。
- 多行提交信息写进 `.git/` 下的临时文件再 `git commit -F <file>`
  （信息含中文引号时 `-m` 会被 shell 截断）。
- **判断某个状态只看 `git show HEAD:<file>`，不看工作区**；**判断是否已推送只看远端**。
- 本轮临时文件统一放仓库内 `.ci-tmp/`（实测该目录不进 `git status`，不污染暂存集）。

### 6.3 本轮（收尾这一轮）对仓库的改动
- 新增本文件 `docs/handover/HANDOVER-CURRENT.md`。
- `6eefcb0`：`ZhishengWeather/AppDiagnosticsStore.swift` —— iOS 18 API 改用 iOS 14 完成回调版（P-23）。
- `9660e9d`：`Core/Networking/SevenTimerResponse.swift` + `SevenTimerMapper.swift`
  —— `init` 保留字改名 `initTime` + 显式 `CodingKeys`（P-28）。
- 另有 `.workbuddy/memory/MEMORY.md`（工作区记忆，**不在本仓库内**）被精简重写：
  原 12,323 字符超限被截断 → 2,495 字符，指向本文与 `docs/CI-pitfalls.md`。

---

## 7. 文档分工约定（用户明确纠正过的一条）

- **`README.md` 是写给"外人"的**（想装来用的人 + 路过看代码的开发者），
  **不是**给接手人看的内部笔记。
- **内部内容**（内部编号如 `AC-Axx` / `SC-xx`、CI 踩坑复盘、重构代价对比、真机验收清单）
  一律放 `docs/` 下的维护者笔记（已有 `docs/DEV-NOTES.md`、`docs/CI-pitfalls.md`、
  `docs/handover/` 系列）。
- **不要把这些塞进 README。** 已知的 `README.md`（226 行）与 `docs/DEV-NOTES.md`（346 行）
  就是按这条分工重写过的产物。

---

## 8. 下一轮建议的起手顺序

1. **先看 CI**：确认 `9660e9d`（或其后继）的 `iOS Build` 结论。若仍 failure，**只修那一条编译错**，
   再推、再看，循环到测试 step 真正跑起来为止
   （注意 P-20：编译失败时测试从没跑过，"绿"可能是假象；P-30：一次通常只暴露一条错，别期待一步到位）。
   ⚠️ 还要留意 **`Archive` / `Package unsigned IPA` / `Upload unsigned IPA` 三个 step 会在测试失败时
   全部 `skipped`** —— 也就是说 **CI 红着的时候根本不会产出新 IPA**（这与 §4.3「版本号没变」直接相关）。
   **测试 step 变绿之后，才第一次可能有新包可装。**
2. **再验真机问题**（§4）：小组件当前位置落哪个空态 / 实时活动是否启动 / 版本号是否随构建号变化。
   凡是 entitlements 相关的，**必须真机**，CI 不算数。
3. **卫星云图接线**（§4.5）：批次 B（写 View）+ 批次 C（装配进 `ContentView`），
   装配后确认**存在引用点**。
4. **接手任何"看起来已完成"的功能前，先按 §6.2 用 `git show HEAD:<file>` 与远端核实**，
   不要凭文档或上一轮摘要下结论。

> 最后一条元纪律：**本项目的失败模式几乎全是"依据错了"而不是"实现难"。**
> 每条结论都问一句"我凭什么知道这个" —— 如果答案是"文档这么写的"或"周围代码这样写的"，
> 就还没核实完。
