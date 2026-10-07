//
// CI 踩坑全记录（run1 → run37 攻坚复盘）
// 目的：下次从零搭 iOS CI 或改 Swift 代码时，先读这份，别再踩一遍。
// 每条都是 CI 实测踩出来的，不是理论推演。
//

# ZhishengWeather iOS CI 踩坑全记录（run1 → run37）

> 背景：Windows 侧开发纯 Swift + SwiftUI 项目，唯一编译门禁是 GitHub Actions
> macOS runner（Xcode 15.4 + XcodeGen 现生成工程）。从 run1 到 run8 共修 5 轮。
> 结论先行：**每一轮失败都是"修 A 暴露 B"的分层暴露**——错误被前一个更严重的
> 错误挡住，编译器不会一次报完。修 bug 要有打持久战的心理预期。

---

## 一、CI 工具链（macOS runner）

### P-01 XcodeGen 版本锁死 2.42.0（run1）
- **现象**：`brew install xcodegen`（≥2.44.1）生成的工程 `objectVersion 77`
  （Xcode 26 格式），Xcode 15.4 直接拒读："future Xcode project file format (77)"。
- **修法**：从 GitHub Releases 下载 2.42.0 二进制（zip 内是
  `xcodegen/bin/xcodegen` + `xcodegen/share/xcodegen/`），bin 装到
  `/usr/local/bin`，share 装到 `/usr/local/share/`。
- **规约**：**禁止 `brew install xcodegen`**。升级 XcodeGen 前先确认
  runner 的 Xcode 版本能读它的 objectVersion。

### P-02 pipefail + `| head -n1` = SIGPIPE 141（历史轮）
- **现象**：`set -o pipefail` 下 `grep ... | head -n1`，head 提前关管道，
  上游收到 SIGPIPE → 整个 step 判失败。
- **修法**：让上游自己在首个匹配处停：`grep -Eom1`；歧义匹配时补
  `|| true`（注意 `||` 优先级低于 `|`，作用于整条管道）。
- **附带坑**：`set -e` 下 `DEVICE=$(...)` 赋值失败会直接中止脚本，
  后面的诊断代码永远执行不到。

### P-03 `if-no-files-found: ignore` 会掩盖问题（历史轮）
- **现象**：`xcodebuild test` 没带 `-resultBundlePath`，上传步骤永远
  匹配不到 `*.xcresult`，但 `ignore` 策略把问题静默吞了。
- **规约**：产物上传步骤用 `if-no-files-found: error`，缺产物要炸出来。

---

## 二、Swift 并发隔离（run3 + run4，合计 13 处错误）

### P-04 default 参数在调用方的非隔离上下文求值（run3）
- **现象**：`init(locationProvider: LocationProvider = LocationProvider())`，
  `LocationProvider` 是 `@MainActor` 类 → "call to main actor-isolated
  initializer in a synchronous nonisolated context"。
- **原理**：默认参数表达式在**调用方**的隔离上下文求值，不在被调方。
- **修法**：默认值给 `nil`，真正创建挪进 init 体内（体内已是本类的
  `@MainActor` 隔离）：
  ```swift
  init(locationProvider: LocationProvider? = nil) {
      self.locationProvider = locationProvider ?? LocationProvider()
  }
  ```

### P-05 App 入口存储属性初始化器同理（run3）
- **现象**：`@State private var viewModel = WeatherViewModel()`（VM 是
  `@MainActor`）在 `struct App` 里挂编译。
- **修法**：给 `struct XxxApp: App` 整体标 `@MainActor`（Apple 官方模式）。

### P-06 SwiftUI View 只有 body 推断主 actor（run4，10 处）
- **现象**：View 的 `init` / 辅助计算属性 / 方法默认**非隔离**，触碰
  `@MainActor` 的 VM 属性直接硬错误（Xcode 15.4 SDK 下 View 协议
  未整体 MainActor 化）。
- **修法**：**项目规约：所有 View 结构体整体标 `@MainActor`**。
- **重要教训**：run3 修掉 3 个错后 run4 才暴露这 10 个——**错误是分层
  暴露的**，语法错会挡住类型检查，别指望一轮修完。

### P-07 属性与方法重名 = invalid redeclaration（run3）
- **现象**：`@State private var showMinimumHint: Bool` 和
  `private func showMinimumHint()` 同名 → redeclaration 错误。
- **规约**：副作用方法用动词前缀（`triggerXxx` / `performXxx`），
  状态属性用名词。

### P-08 AppIntents `@Parameter default:` 必须编译期字面量（run2）
- **现象**：`@Parameter(title:) var city: WidgetCityEntity` 的
  `default: WidgetCityEntity.followApp`（静态属性）→
  "Expect a compile-time constant literal"。
- **修法**：删掉 `default:`，默认值走 `EntityQuery.defaultResult()`；
  `typeDisplayRepresentation` 用 `TypeDisplayRepresentation(name: "字面量")`。

---

## 三、XCTest 写法（run5 + run6）

### P-09 带 `accuracy:` 的断言不收可选（run5）
- **现象**：`XCTAssertEqual(snapshot.hourly.first?.temperature, 23.4,
  accuracy: 0.001)` → `Double?` 不能转 `Double`。
- **修法**：`try XCTUnwrap` 先解包再断言。

### P-10 单参闭包必须显式忽略参数（run6）
- **现象**：`(0..<4).map { 20.0 }` → "contextual type for closure
  argument list expects 1 argument, which cannot be implicitly ignored"。
- **修法**：写 `map { _ in 20.0 }`。

### P-11 实参顺序要对齐签名（run6）
- helper 签名 `daily → currentTemp → isDay`，测试实参写反 →
  "argument 'currentTemp' must precede argument 'isDay'"。
- **规约**：测试辅助函数的默认参数排布尽量把"常用必填"放前面。

---

## 四、测试设计（run7，最隐蔽的一层）

### P-12 竞态单测必须让首请求真正起飞（run7）
- **现象**：主 actor 上**同步连发**两次 `queryChanged`，第一个防抖
  Task 在起跑前就被第二次的 `cancel()` 掐死——竞态根本没构造出来，
  唯一发出的请求反而是"延迟返回第一次结果"的那个，断言必挂。
- **修法**：两次输入之间 `try? await Task.sleep(nanoseconds: 100_000_000)`
  让出主线程，确保第一次请求进入飞行中。
- **规约**：测"晚到响应被丢弃"这类竞态，**先验证前置时序真的发生了**
  （可临时打印 generation/调用序号自检），再断言结果。

### P-13 业务规则冲突要回归文档裁定，不能两头猜（run7）
- **现象**：`upsertCurrentLocation` 实现按"规范化 id 命中手动城市 →
  no-op（Q5）"写，测试按"已有当前位置项就一律就地更新"写，CI 一跑
  才发现规则 2 和规则 3 优先级矛盾（测试用北京坐标撞默认城市暴露）。
- **裁定**：已有"当前位置"项 → 一律就地跟随用户真实坐标（优先级最高）；
  Q5 的"视为同一城市 no-op"仅在**尚无**当前位置项时适用。
- **规约**：**规则有交互时，文档要写明优先级顺序**，别只写并列的
  条目让实现和测试各自解读。

---

## 五、本机工程环境（Windows 侧）

### P-14 push 卡 credential helper
- **现象**：`git push` 在 401 后挂死（等凭据 GUI/TTY），被沙箱 SIGTERM。
- **修法**：token 塞 URL 绕过 helper：
  ```bash
  TOKEN=$(printf 'protocol=https\nhost=github.com\n' | git credential fill | grep '^password=' | cut -d= -f2)
  git push "https://x-access-token:${TOKEN}@github.com/<owner>/<repo>.git" <branch>
  ```

### P-15 代理与网络
- 本机直连 GitHub HTTPS 不通（schannel 握手失败）；**代理
  `http://127.0.0.1:7897` 可用**（WorkBuddy 内置代理 5409 不通，502）。
- **run37 追加实证**：shell 环境里的 `HTTP_PROXY`/`HTTPS_PROXY`
  =`http://127.0.0.1:2586` 是**坏出口**（`CONNECT tunnel failed, 502`），
  而它**优先级高于 git 默认**，会让 `git push` 连续 10+ 次全失败。
  绕行（已验证可推成功）：
  ```bash
  git -c http.proxy=http://127.0.0.1:7897 \
      -c https.proxy=http://127.0.0.1:7897 push origin <branch>
  ```
  排查要点：**Python urllib 与 git 走同一代理结果可能不同**，必须分别实测；
  Windows 系统代理读 `winreg` 的
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
  （`ProxyEnable` / `ProxyServer`）。
  瞬时 `SSL_ERROR_SYSCALL` 会间歇出现，重试 2-3 次即过，不要直接判死。
- 走代理的 API 调用**间歇性空响应/SSL 中断**——所有 curl 都要套
  重试循环 + 结果校验（`grep -q total_count` 之类），裸调必踩。
- GH007：commit 邮箱必须用 GitHub noreply
  （`166398578+woyaoxingfua@users.noreply.github.com`），否则 push 被拒。

### P-16 Windows Python 读不了 Git Bash 的 `/tmp`
- Git Bash 的 `/tmp/xxx` 与 Windows Python 的路径映射不一致，
  `json.load(open('/tmp/...'))` 直接 FileNotFoundError。
- **规约**：临时文件放**工作目录**，不放 `/tmp`。

---

## 六、复盘结论（下次开工先读这六条）

1. **错误分层暴露**：编译错误按严重度逐轮冒出，一次 push 只能测出
   当前最表层的一层。预算 3-5 轮 CI，别指望一把过。
2. **View 整体 @MainActor** 是本项目铁律；VM/Model 是 @MainActor 类
   时，非隔离上下文触碰其成员是硬错误。
3. **XcodeGen 锁 2.42.0**，禁 brew。
4. **竞态测试先自证时序**，再断言结果。
5. **规则文档写优先级**，实现与测试不得各自解读。
6. **网络操作全部套重试**（代理间歇抽风），凭据问题用 token 嵌 URL。

---

## 七、Swift 可选元素数组（run35）

### P-17 `[T?]?` 的元素访问是**双层可选**，链式调用会断
- **现象**：DTO 字段声明为 `[FlexibleTime?]?`（数组可缺 + 元素可 null）时，
  `daily.sunrise?.first` 的类型是 **`FlexibleTime??`**，写
  `daily.sunrise?.first?.isoString` 只能解一层 →
  `error: value of optional type 'FlexibleTime?' must be unwrapped
  to refer to member 'isoString'`（同一处错 6 遍，全是测试代码）。
- **原理**：对 `Array<T?>` 做链式访问时，`first` 的类型是 `Element?`
  = `(T?)?` = `T??`。
  **区别在于元素是否可选**：
  - `[DailyForecast]?` → `?.first` 得到 `DailyForecast?`（单层）→ 正常；
  - `[FlexibleTime?]?` → `?.first` 得到 `FlexibleTime??`（双层）→ 断。
  所以 `?.first?.member` 这个写法**有时能编过有时编不过**，不能凭印象判断。
- **修法**（三选一）：
  ```swift
  // ① 显式助手（推荐，语义最清楚）
  private func sunTime(_ times: [FlexibleTime?]?, at index: Int = 0) -> FlexibleTime? {
      guard let times, times.indices.contains(index) else { return nil }
      return times[index]
  }
  // ② 先解数组再取元素
  let rows = try XCTUnwrap(snapshot.daily); let firstRow = try XCTUnwrap(rows.first)
  // ③ 扁平化：`times.first ?? nil`
  ```
- **规约**：遇到 `[T?]?` 一律**显式解包或走助手**，不要链 `?.first?.member`。
  改动后可用 Python 正则扫全仓（模式：`?` `.` `(first|last)` `?` `.`，
  中间允许空白）做一次体检；
  但**命中不等于有问题**——必须回到元素类型判断，避免过度修改
  （run35 扫描命中 9 处，其中 8 处元素非可选、CI 早已证明能编过，不动）。

---

## 八、最大的那条：同源盲区（run37，代价最高）

### P-18 单测 Stub 与实现共享同一套假设 → 真机缺陷必然逃逸
- **现象**：请求 `api.open-meteo.com/v1/forecast` 带 `timeformat=unixtime`
  时，`daily.sunrise`/`daily.sunset` 实测返回 **epoch 整数**
  （`sunrise:[1789422908]`）。而设计文档 ARCH-A1 §1.4 断言"二者绕过
  unixtime，仍是 ISO 本地墙钟字符串"——**该论断是错的**。
- **后果**：DTO 声明 `[String?]?` → 真机 JSON 解码 100% 抛 `typeMismatch`
  → 主屏恒显示"格式问题"，实况/逐小时/逐日全量不可用。
  而 **CI 单测一路全绿**：Stub 里 sunrise 写的正是 ISO 字符串，
  与实现的假设**同源**，所以永远测不到。
- **修法**：DTO 改 `[FlexibleTime?]?`（`.epoch` / `.iso` 双态容忍），
  mapper 归一为 `Date`；新增 4 个 epoch/混合形态回归用例。
- **规约（本项目铁律）**：
  1. 任何对**第三方 API 行为**的断言（字段类型、是否受某参数影响、
     键是否总是存在）**必须用真实响应验证过**，不能只信文档、不能只靠 Stub。
  2. 验证手法固定为：**用 Python 逐字复刻 App 实际发出的完整 URL，
     打真实 API，逐字段比对 DTO 声明的类型**（整数→Int 是否成立、
     数字→String 必炸、null→非可选必炸、缺键→非可选必炸）。
     这比读代码猜快得多，且能一次性扫掉所有字段。
  3. 修完要**反过来问**："这个缺陷为什么没被现有测试抓到？"
     若答案是"测试数据和实现同源"，那必须补一个**真机形态**的用例，
     否则同类缺陷还会再来一次。

---

## 九、CI 绿 ≠ 真机对：未签名产物的能力真空（真机复盘）

### P-19 未签名 IPA 的 App Group 失效（真机反馈：小组件永远「暂无数据」）
- **现象**：CI 产物（unsigned IPA）侧载到真机后，**主 App 一切正常，
  小组件永远显示「暂无数据」**——不是「共享数据不可用」也不是「已过期」，
  而是共享容器里从头到尾没有主载荷（渲染器三态文案本身是正确行为，
  不是 bug）。
- **根因**：`.github/workflows/ios.yml` 以 `CODE_SIGNING_ALLOWED=NO` 出
  **完全未签名**的 IPA。没有签名 → 没有 provisioning → 两个 target 的
  entitlements 文件（App Group `group.com.zhisheng.weather`）**从不生效**
  → 主 App 与 Widget 扩展各拿一个**互相隔离的沙盒容器**，共享容器写入
  与读取落在两个不同的"group.com.zhisheng.weather"里 → Widget 读到的
  永远是空。
- **为什么 CI 测不出来**：单测的共享容器是**注入的独立 UserDefaults
  suite**（AppGroupStoreTests 同款纪律），读写发生在**同一进程同一容器**，
  根本不经过 entitlements 校验；CI 的 xcodebuild test 也不含签名环节。
  所以这条链路（写共享容器 → 跨进程读）在 CI 上**结构性不可见**。
- **修复路径（需用户证书资产，CI 侧未实施）**：
  1. 付费开发者账号；在开发者中心为 `com.zhisheng.weather` 与
     `com.zhisheng.weather.widget` 两个 App ID **都**开启 App Group
     capability（挂同一个 group）；
  2. 出一张覆盖两个 bundle id 的 provisioning profile（或各一张）；
  3. CI 改签名构建：`CODE_SIGNING_ALLOWED` 恢复默认 + 配置
     `DEVELOPMENT_TEAM` / 证书（或用 `ldid` 伪签名**保留 entitlements**）；
  4. 侧载分发走 SideStore / AltStore 等会**保留 entitlements** 的签名
     工具——直接重签但丢 entitlements 的工具会让 App Group 再次失效。
- **规约**：凡用到 entitlements 才能生效的能力（App Group / 推送 /
  associated domains），CI 全绿**不能**作为真机可用的证据；真机验收
  必须在签名产物上做，且验收清单要含「跨进程共享读写」用例。

---

## 十、编译失败遮蔽测试红灯（run114 → run137 实证）

> 本节是上面「六、复盘结论」第 1 条「错误分层暴露」的**机制升级**：
> 那条讲的是*编译错误*之间互相遮挡；本节讲的是**编译错误把测试红灯
> 一起遮住**。两者叠加，才产生「修一处、CI 又暴露下一处」的连续 10+ 轮。
> **本节的量化数字全部来自 GitHub API 实测**（采集脚本见文末「取证方法」）；
> 方案部分标注「未实测」。

### P-20 单一 step 同时承担编译与测试 → 编译失败时测试根本没跑（run114–run137）

- **现象**：`.github/workflows/ios.yml` 第 64–74 行只有一个
  `Run unit tests (simulator)` step，里面是
  `xcodebuild test`。该命令**先编译整个 test target（含 1197 个测试函数），
  编译全部成功后才进入执行阶段**。只要有 1 个编译错误，执行阶段
  **一个测试都不会跑**——红灯不存在，不是"绿"，是"从未被检验"。
- **实测证据（run114–run138 共 25 次失败，全部红在同一个 step）**：

  | 失败类型 | 次数 | run 区间 | 注解里的证据 |
  |---|---|---|---|
  | **编译失败**（测试从未执行） | **19** | run114–run132 | `file.swift:行:列: error: ...` + `** TEST FAILED **` |
  | **测试断言失败**（编译通过） | **5** | run133–run137 | `-[Suite testMethod] : XCTAssert... failed` |
  | 无法取到注解（见下） | 1 | run138 | jobs 列表为空 |
  | 编译与断言同时出现 | **0** | — | 这是关键：两类失败从不共存 |

  最后一行是整节的核心：既然编译失败时**一条断言注解都不会产生**，
  那么 CI 上看到的"全是编译错"**不是"测试没问题"，而是"测试没跑"**。

- **⚠️ 日志措辞本身在骗人**：`grep` 到的 `** TEST FAILED **` 样板行
  在**编译失败**的 run 里同样出现（run114 的注解里就有）。xcodebuild
  编译崩了照样打 `** TEST FAILED **`。所以"日志里写着 TEST FAILED"
  **不能**推出"有测试跑挂了"。必须看有没有
  `-[Suite testMethod] :` 形态的注解——那才是真跑了测试的标志。
- **量化结论：被遮蔽的红灯**。把 15 条真实红测逐条回溯到它的引入提交
  （`git log --reverse -S '<方法名>'`），再看引入它的那次 CI 属于哪类失败：

  | 测试文件 | 方法数 | 引入于 | 引入轮失败类型 | 首次实际报红 |
  |---|---|---|---|---|
  | `MarineFloodSourcesTests.swift` | 1 | `f0382c4` | run114 **COMPILE** | run133 |
  | `RadarTileTests.swift` | 2 | `fac5bb6` | run114 **COMPILE** | run136 |
  | `UVIndexGuideTests.swift` | 4 | `da77541` | run119 **COMPILE** | run136 |
  | `NmcAlarmTests.swift` | 1 | `bde61e2` | run120 **COMPILE** | run133 |
  | `RadarPixelShiftTests.swift` | 7 | `d715851` | run124 **COMPILE** | run133/134 |

  **15/15（100%）**：每一条红测都是**先**在一次编译失败的 CI 里进入代码库、
  **后**在编译修好之后才浮出来。**编译失败共遮蔽了 15 条测试红灯。**
- **遮蔽时长**：最早的 `MarineFloodSourcesTests` 与 `RadarTileTests`
  在 run114（2026-10-06T11:40:50Z）入库，直到 run133
  （2026-10-06T15:58:12Z）才第一次报红 —— **被遮蔽 19 次 CI 推送、
  约 3 小时 55 分钟**。全量 15 条从引入到暴露，横跨 run114→run137
  （约 19 小时）。
- **为什么这条坑以前没被记下来**：P-03 记的是"产物上传用
  `if-no-files-found: ignore` 会静默吞问题"，P-19 记的是
  "CI 绿 ≠ 真机对"。**两者都没覆盖「编译与测试混在一步」这个结构性缺陷。**
  之前 19 次编译失败里，有 18 次的注解里一条断言都没有，我们当时读到的是
  "这次又是编译错"，于是继续修编译——**红灯被合法地、一次又一次地推迟**。
  修编译本身没错（它是必修项），但缺一个"编译是否已通过"的显式判据，
  就永远只能一轮见一层。

### P-21 取证时的两个 API 坑（省得下次重踩）

- `check-runs/{id}/annotations` 的 `{id}` 是 **check-run id**，
  即 `actions/runs/{run_id}/jobs` 里 `jobs[0].id`，**不是** workflow run id。
  传错会拿到 `{"message":"Not Found"}`——且这个错误响应是 **HTTP 200**，
  脚本里 `if (resp.ok)` 判断不出来，会静默解析成"0 条注解"。
  **判空必须判 `message == "Not Found"`，不能判 HTTP 状态码。**
- `annotations` 端点返回的是**裸 JSON 数组**，不是带 `total_count` 的对象。
  解析时要同时兼容两种形态。

### P-22 方案评估（⚠️ 以下 YAML/脚本**均未实测** —— 本机 Windows 无 Xcode）

> 纪律：本节所有 workflow 改动**没有在 macOS runner 上跑过**。
> 首次启用请当作一次独立改动单独提交、单独观察一轮 CI。

#### 方案 A（**推荐**）：编译与测试拆成两个 step

- **做法**：`build-for-testing`（只编译，产出 `.xctest`）→
  `test-without-building`（只执行）。两者共用同一个
  `-derivedDataPath`，第二步复用第一步的产物。
- **为什么是它**：它**把归因问题从根上消掉**。第一步红 = 编译问题，
  第二步红 = 测试问题，两者在 GitHub UI 上是两个独立的 step、
  两条独立的注解流。不需要任何"从日志猜是哪一类"的启发式规则。
  顺带**省时间**：编译只跑一次（`test` 本来也是编一次），
  而第二步在编译失败时**秒级失败**而不是重编。
- **代价**：`test-without-building` 必须严格复用 `-derivedDataPath`
  与 `-destination`；两者不一致会得到"跑了 0 个测试"这种**假绿**，
  是本方案唯一的真实风险（缓解见下方断言）。
- **取舍**：`xcodebuild test` 一步版更短，但正是这个"短"造成了 19 次遮蔽。
  改动量约 15 行 YAML，无脚本、无新增依赖。

#### 方案 B：保留单 step，事后按 xcresult 存在性分流

- **做法**：单 step 内先 `xcodebuild test`，用
  `rc=$?` 兜住失败码，再判 `-f build/TestResults.xcresult`：
  有 → 跑测试阶段失败；无 → 编译失败，直接 `::error::COMPILE_FAILURE`。
- **优点**：改动最小，不动 `xcodebuild` 调用方式。
- **缺点（决定了它不能做主方案）**：分流**完全依赖 xcresult 是否落盘**。
  编译崩在中途时 xcresult 可能落一个**不完整**的包，此时会把编译失败
  误判成测试失败——**从"看不出"变成"看错了"，比现状更危险**。
  另外它仍然只有 1 个 step，GitHub UI 上两类失败还是挤在一起。
- **定位**：A 的补充。若暂不想拆 step，可先上 B 拿显式判据。

#### 方案 C：测试清单守卫（防"测试没被编进 target"）

- **做法**：仓库存一份测试方法清单，CI 跑完比对"实际执行的测试数"。
  本仓库当前基线（实测，2026-10-07）：**95 个测试文件 / 1197 个测试函数**。
- **它能抓什么**：测试文件没进 `sources`、被 `@available`/条件编译排除、
  或被 scheme 的 `test.targets` 漏掉——即"**编进去了但没跑**"。
- **它抓不到什么（本方案的真实短板）**：**抓不到编译失败遮蔽**。因为
  清单与"实际执行数"的比对发生在测试**跑完之后**，而编译失败时根本没有
  "跑完之后"这个时刻。所以 **C 不能替代 A**，只能叠加。
- **代价**：清单文件要随每次新增测试手工更新，否则天天误报；
  静态正则匹配函数名会与 `@Test` 宏、辅助方法产生歧义。
  **本仓库 XCTest 写法统一（1197 个 `func testXxx`，无 `@Test`），
  清单可自动生成**，维护成本可控——但这一点是**按当前代码风格推断**的。

#### 方案 D（补充，成本最低，建议与 A 一起上）：注解里区分失败类别

- 在现有 `Report test failures as annotations` 里加一行判据：
  若日志有 `-[Suite testMethod] :` 形态的注解 → 额外打一条
  `::error::TEST_FAILURE`；否则打 `::error::COMPILE_FAILURE`。
- 这不改任何构建行为，只是让**红在哪一类**一眼可见，成本约 5 行。
- 它**不能**让测试提前跑起来（仍被编译遮蔽），但能让"这次是编译挡了"
  立刻可读——**直接解决本次 19 次遮蔽里"看不出真相"的那部分损失**。

#### 推荐组合

**A + D**。A 消除遮蔽（治本），D 让残余失败的归因一眼可读（治标，兜住
A 覆盖不到的情况，如"Archive/IPA 步骤的失败"）。C 作为后续增强。
**不建议单独用 B**（误判风险大于收益），C 单独用**解决不了本问题**。

<details>
<summary>可直接复制的 YAML 片段（替换现有 "Run unit tests (simulator)" step）——<strong>未实测</strong></summary>

```yaml
      # ── 编译与测试分离：编译失败与测试失败分别归因（方案 A，未实测）──
      # 纪律：DerivedData 路径必须与下一步**完全一致**，否则
      # test-without-building 找不到 .xctest，会报「跑了 0 个测试」＝假绿。
      - name: Compile tests (build-for-testing)
        run: |
          set -euo pipefail
          mkdir -p build
          # 承 P-02：tee 在管道末端，pipefail 保证 xcodebuild 失败码能传出；
          # 禁止把 tee 换成 `| head`。
          xcodebuild build-for-testing \
            -project ZhishengWeather.xcodeproj \
            -scheme ZhishengWeather \
            -destination "platform=iOS Simulator,OS=latest,name=${{ steps.sim.outputs.device }}" \
            -derivedDataPath build/DD \
            CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/xcodebuild-build.log

      - name: Run unit tests (test-without-building)
        run: |
          set -euo pipefail
          rm -rf build/TestResults.xcresult
          xcodebuild test-without-building \
            -project ZhishengWeather.xcodeproj \
            -scheme ZhishengWeather \
            -destination "platform=iOS Simulator,OS=latest,name=${{ steps.sim.outputs.device }}" \
            -derivedDataPath build/DD \
            -resultBundlePath build/TestResults.xcresult \
            CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/xcodebuild-test.log
          # 防空跑：build-for-testing 产物缺失时 xcodebuild 可能 0 测试 0 失败，
          # 那就是**假绿**。这里显式判产物在不在。
          test -e build/DD/Build/Products/Debug-iphonesimulator/ZhishengWeatherTests.xctest

      # 方案 D：把失败类别直接写进注解。未实测。
      - name: Report test failures as annotations
        if: failure()
        run: |
          set -euo pipefail
          # 编译阶段也可能打出 "** TEST FAILED **"，**不能**拿它判断"测试跑挂了"。
          # 真跑过测试的唯一标志是 -[Suite testMethod] : 形态的注解。
          if grep -qaE '\-\[[A-Za-z0-9_]+\.[A-Za-z0-9_]+ test[A-Za-z0-9_]+\]' build/xcodebuild-test.log 2>/dev/null; then
            echo "::error::TEST_FAILURE——测试确实执行了，红灯是真断言失败（见下方条目）"
          else
            echo "::error::COMPILE_FAILURE——本次没有任何测试被执行；下方为编译错误，测试状态未知"
          fi
          for LOG in build/xcodebuild-build.log build/xcodebuild-test.log; do
            [ -f "$LOG" ] || continue
            # 截断**必须**用 awk 'NR<=40'，**不能**用 head -40（P-02 同源坑）：
            # head 会关管道，上游收到 SIGPIPE(141)，pipefail 把这条
            # 「报告失败」的步骤自己判失败，反而掩盖真正的失败原因。
            grep -aE "error:|XCTAssert[A-Za-z]* failed|failed - |TEST FAILED" "$LOG" \
              | sed -e 's/\r$//' \
              | awk 'NR<=40' \
              | while IFS= read -r line; do
                  escaped=$(printf '%s' "$line" | sed 's/%/%25/g')
                  echo "::error::$escaped"
                done
          done
```

方案 C 的清单守卫片段（**未实测**）：

```bash
# scripts/check-test-manifest.sh —— 校验"编进 target 的测试"与"清单"一致
# 基线：95 个测试文件 / 1197 个测试函数（2026-10-07 实测）
set -euo pipefail
MANIFEST=scripts/test-manifest.txt
RES=build/TestResults.xcresult
EXPECTED=$(grep -c . "$MANIFEST")
# Xcode 15.4 的 xcresulttool 尚未强制 --legacy；Xcode 16+ 需补 --legacy。
# 递归搜 counts 键，避免依赖 JSON 里随版本变动的层级路径。
ACTUAL=$(xcrun xcresulttool get --path "$RES" --format json | python3 -c '
import json, sys
def walk(o, out):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "testsCount" and isinstance(v, dict) and "_value" in v:
                out.append(int(v["_value"]))
            else:
                walk(v, out)
    elif isinstance(o, list):
        for v in o:
            walk(v, out)
r = []
walk(json.load(sys.stdin), r)
print(max(r) if r else 0)
')
if [ "$ACTUAL" -ne "$EXPECTED" ]; then
  echo "::error::测试数不符：清单 $EXPECTED 条，实际执行 $ACTUAL 条 —— 有测试没被编进 target 或没跑到"
  exit 1
fi
```

</details>

### 无法确定的部分（不猜）

- **run138**：`conclusion=failure`，但 `actions/runs/{id}/jobs` 返回
  `jobs: []`、注解为 0 条。**取消/排队/基础设施类失败都有可能**，
  现有权限下无法判定是哪一种，故未计入 19/5 之外的任何归因。
- **run139**：抓取时 `conclusion=null`（仍在跑），未纳入统计。
- **每次失败到底漏了几条**：现workflow 的注解抽取有
  `awk 'NR<=40'` 上限，且 `Upload test results` 用的是
  `if-no-files-found: ignore`。**因此"15 条"是下界，不是上界**——
  19 次编译失败期间被遮蔽的红灯**可能多于 15 条**（同一次编译失败
  会遮蔽当时树里所有跑不到的红测，而不只是最终浮出来的那几条）。
  要拿到精确数字，需要让 CI 在编译失败时也落一份"应跑测试数"的基线
  （即方案 C）。

### 取证方法（可复现）

```bash
# 公开仓库免认证。① 取 run 列表（ios 分支）
curl -s -m 20 --ssl-no-revoke --compressed \
  "https://api.github.com/repos/woyaoxingfua/ZhishengWeather/actions/runs?branch=ios&per_page=30"
# ② 取 jobs（注意是 jobs[0].id，不是 run id）
curl -s ... "https://api.github.com/repos/woyaoxingfua/ZhishengWeather/actions/runs/{run_id}/jobs"
# ③ 取注解（id = 上一步 jobs[0].id）
curl -s ... "https://api.github.com/repos/woyaoxingfua/ZhishengWeather/check-runs/{jobs[0].id}/annotations"
# ④ 关联"红测何时入库"用 git（本地）：
git log --reverse -S '<测试方法名>' -- ZhishengWeatherTests/
git merge-base --is-ancestor <引入SHA> <run 的 head SHA>   # 判断它进了哪一次 CI
```

判读规则（本次即用）：

| 注解里出现 | 判定 |
|---|---|
| `** TEST FAILED **` | **不可判定**（编译失败时也会打，见 P-20） |
| `-[Suite testMethod] :` | 真跑过测试，**测试失败** |
| `path/File.swift:行:列: error:` | **编译失败**，测试未执行 |
| 两者都没有 | 归因不了，看不出是编译还是测试（run110 的情况） |

