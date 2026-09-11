//
// CI 踩坑全记录（run1 → run8 攻坚复盘）
// 目的：下次从零搭 iOS CI 或改 Swift 代码时，先读这份，别再踩一遍。
// 每条都是 CI 实测踩出来的，不是理论推演。
//

# ZhishengWeather iOS CI 踩坑全记录（run1 → run8）

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
