# 交接文档：枳生天气 iOS · 从 Windows 迁移到豆包云电脑（Linux）

> 写给：在新环境接手本项目的人（或新会话的 AI 助手）
> 日期：2026-09-11 ｜ 交接时项目状态：**A1 批次已交付，CI 全绿（run13 / commit `7f569ef`）**
> 本文目标：让你在 Linux 云电脑上**从零 clone 到产出下一个 IPA**，不需要问任何人任何问题。

---

## 0. 一句话项目现状

把 Android 开源天气 App（`zhishengplus/ZhishengWeather`，Kotlin/Compose）用**纯 Swift + SwiftUI** 重写为 iOS 版（clean-room 重写，与原仓库零代码共享），含 WidgetKit 小组件。开发机无法编译 iOS，**唯一编译/测试门禁是 GitHub Actions 的 macOS runner**，产物是未签名 IPA，用户用付费证书自签 sideload。

- 仓库：`https://github.com/woyaoxingfua/ZhishengWeather`（用户 fork），分支 **`ios`**（开发主线）
- 最新绿 CI：run13（`7f569ef`），161 个测试全过，IPA artifact 名 `ZhishengWeather-unsigned-ipa`
- 已完成：MVP（P0 11 项）→ P1 三特性（F-A 逐日/F-B 多城市/F-C 组件城市选择）→ A1 批次（气压/24h/15天/日出日落/昨日对比/锁屏组件/交互刷新/快捷方式）
- 进行中：**功能对齐三批计划**（`docs/handover/PRD-zhisheng-ios-A.md`）——A1 ✅ 已交付，**A2（空气质量+一句话摘要+生活指数）待开工，A3（历史天气+设置页）在 A2 后**

---

## 1. 先读这五份文档（都在仓库 `docs/handover/` 里，clone 即得）

| 顺序 | 文件 | 作用 |
|---|---|---|
| ① | `PRD-zhisheng-ios-A.md` | **当前路线图**。37 项差距对照 + 三批排布。看 §3 的 A2 表格就是下一个迭代的需求 |
| ② | `ARCH-zhisheng-ios.md` | 全量架构基线（文件清单/接口契约/跨层纪律 §7.8 必读） |
| ③ | `ARCH-zhisheng-ios-A1-increment.md` | 增量设计的**体例样板**——A2 的架构文档照这个格式写 |
| ④ | `open-meteo-capability-verified.md` | Open-Meteo API 能力实测（A2 空气质量 API 已验证可用，直接抄参数） |
| ⑤ | `original-android-README.md` | 原 Android 本体功能清单（对齐基准） |

另有两份历史文档没复制进仓库（内容已被 A 系列 PRD 覆盖，需要时去旧盘拿）：`PRD-zhisheng-ios.md`（MVP 版）、`PRD-zhisheng-ios-P1.md`。

---

## 2. Linux 云电脑环境搭建（从零开始，逐步执行）

### 2.1 装 git 并 clone 仓库

```bash
# 大多数 Linux 发行版自带 git，没有就装：
sudo apt install git        # Debian/Ubuntu
sudo dnf install git        # Fedora/RHEL

# clone（HTTPS 即可，push 时再配凭据）
git clone https://github.com/woyaoxingfua/ZhishengWeather.git
cd ZhishengWeather
git checkout ios            # 开发主线在 ios 分支！
git log --oneline -3        # 应看到 7f569ef 在顶部
```

### 2.2 配置 git 身份（**不做这步 push 会被 GH007 拒绝**）

用户的 GitHub 账号开启了邮箱隐私保护，commit 必须用 noreply 邮箱：

```bash
git config user.name "woyaoxingfua"
git config user.email "166398578+woyaoxingfua@users.noreply.github.com"
```

### 2.3 配置 push 凭据（三选一，推荐 Personal Access Token）

本机 Windows 的凭据**不会**跟过来，必须重新配：

**方案 A（推荐）：Personal Access Token + 凭据存储**
1. 浏览器登录 GitHub → 右上角头像 → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token
2. 勾选 `repo` 权限（Fine-grained 的话给 `woyaoxingfua/ZhishengWeather` 的 Contents: Read and write）
3. 设个合理有效期，生成后**立刻复制**（只显示一次）
4. 配置存储并验证：
```bash
git config credential.helper store
git push origin ios         # 会提示输入：
# Username: woyaoxingfua
# Password: <粘贴刚才的 token，不是 GitHub 登录密码！>
# 成功后凭据明文存 ~/.git-credentials，后续不再询问
```

**方案 B：GitHub CLI**（`sudo apt install gh` → `gh auth login` → 按提示走浏览器授权）

**方案 C：SSH**（`ssh-keygen` → 公钥贴到 GitHub Settings → SSH keys → remote 换成 git@github.com:...）

### 2.4 网络注意事项（重要）

- 如果云电脑在国内网络直连 GitHub 不稳：配代理或用镜像。git 配代理：
  ```bash
  git config --global http.proxy http://<代理地址:端口>
  ```
  原 Windows 机器用的是 `http://127.0.0.1:7897`（Clash 类工具），云电脑上没有这个代理，**任何照抄这个地址的配置都会连接失败**，要换成云电脑自己的出网方式。
- GitHub API 访问（查 CI 状态、下产物）同样可能需要代理。

### 2.5 你**不需要**在 Linux 上装任何 iOS/Swift 工具链

- 本机永远无法编译 iOS（这是项目既定架构，不是缺陷）。`*.xcodeproj` 不入库，CI 侧用 XcodeGen 现生成。
- Windows 上原来用 Git Bash 跑的 `qa-static-check.sh`（静态纪律检查，41 项），Linux 上直接 `bash qa-static-check.sh` 就能跑，**兼容性只会更好**。
- 全部编译/测试/打包都在 GitHub Actions 上发生（见 §3）。

---

## 3. CI 流水线（你唯一的"编译器"）

`.github/workflows/ios.yml`，push 到 `ios` 或 `main` 分支自动触发，也可手动触发（Actions 页面 → iOS build → Run workflow）。

**流程**：macos-14 runner → 锁 Xcode 15.4 → 装 XcodeGen **2.42.0**（固定版本，禁 brew 最新版——会生成 Xcode 15.4 读不了的 objectVersion 77 工程）→ `xcodegen generate` → 选模拟器 → `xcodebuild test`（全部单元测试）→ unsigned archive → 手工组 Payload → zip 成 IPA → 上传 artifact。

**日常开发循环**：
```bash
# 1. 改代码
# 2. 本地跑静态检查（能抓大部分纪律违规，抓不了编译错误）
bash qa-static-check.sh
# 3. 提交推送
git add -A && git commit -m "feat(A2): xxx"
git push origin ios
# 4. 看 CI：浏览器开 https://github.com/woyaoxingfua/ZhishengWeather/actions
#    绿了 → Actions 页面该 run 底部 Artifacts 下载 ZhishengWeather-unsigned-ipa
#    红了 → 点进 run → 失败的 step → 展开 "Run unit tests" 日志搜 "error:"
# 5. 修 → push → 重复（编译错误要靠 CI 轮次暴露，预算 2-5 轮很正常）
```

**用 API 查 CI 状态（免开浏览器，脚本友好）**：
```bash
# TOKEN 换成你的 PAT
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/woyaoxingfua/ZhishengWeather/actions/runs?branch=ios&per_page=1"
# 看 .workflow_runs[0].status / .conclusion / .head_sha
```

---

## 4. 开发怎么办：两条路线（按你的 AI 助手能力选）

### 路线 A：继续用 WorkBuddy/豆包 AI 协作（无专家团版）

新环境没有本会话的专家团（齐活林/许清楚/高见远/寇豆码/严过关五角色）。**这套 SOP 的本质是文档驱动**，文档全在仓库里，所以接手的 AI 按下面的流程走就能等价替代：

**每个批次的固定流程（以 A2 为例）**：

1. **需求确认**（人工）：读 `docs/handover/PRD-zhisheng-ios-A.md` §3 第二批表格。有疑问直接对 AI 说"按 XX 理解做"，不用等完整评审。

2. **增量架构设计**：让 AI 读以下材料后产出 `docs/handover/ARCH-zhisheng-ios-A2-increment.md`：
   - PRD 的 A2 表格（需求+验收标准 AC-A2-1~27）
   - `ARCH-zhisheng-ios-A1-increment.md`（照这个体例：设计裁定→数据结构→任务列表 T01…Tn→测试设计→风险表）
   - 现网代码：`Core/Networking/OpenMeteoEndpoint.swift`（请求参数）、`Core/Models/`（DTO/快照）、`Core/Storage/AppGroupStore.swift`（共享容器）
   - 给 AI 的提示词模板见 §4.2

3. **实现**：让 AI 按 T 任务逐个写代码，每完成一批跑 `bash qa-static-check.sh`。

4. **验证**：AI 自审（AC 逐条核对）→ 你 push → CI 真编译 → 红了把 error 日志贴给 AI 修 → 绿了下载 IPA。

5. **真机验收**：IPA 自签装到 iPhone，按 PRD 表格里的 AC 逐条人工过（清单控制在 10 条内）。

**A2 批次的关键技术情报（架构师已预研，直接告诉 AI）**：
- 空气质量走**独立域名** `air-quality-api.open-meteo.com/v1/air-quality`，参数 `current=pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,sulphur_dioxide,ozone,us_aqi,european_aqi`（已实测 200 OK）
- **失败隔离铁律**：空气 API 失败绝不能拖垮天气主屏（独立 Result 管道，AC-A2-4）
- **AQI 口径已拍板**：默认美标 us_aqi 着色（国内习惯），欧标数值并列展示
- 一句话摘要 = 纯本地规则引擎，规则优先级固定：强降水 > 温差 > 风 > UV
- 生活指数标注"本地估算·仅供参考"，不得暗示官方

### 4.2 给新 AI 的开工提示词模板（复制即用）

```
项目是一个 iOS 天气 App（Swift/SwiftUI，代码在当前仓库），开发机不编译 iOS，
编译测试全靠 GitHub Actions（push 到 ios 分支自动触发）。

先按顺序读这些文件建立上下文：
1. docs/handover/PRD-zhisheng-ios-A.md —— 只看 §3 第二批（A2）的表格
2. docs/handover/ARCH-zhisheng-ios-A1-increment.md —— 上一批的设计文档，
   你的产出要照这个体例（设计裁定/数据结构/任务列表/测试设计/风险表）
3. docs/handover/open-meteo-capability-verified.md —— API 能力实测
4. 现网代码：Core/Networking/（endpoint+mapper）、Core/Models/、Core/Storage/AppGroupStore.swift

任务：为 A2 批次产出增量架构设计 + 任务列表（写到 docs/handover/ARCH-zhisheng-ios-A2-increment.md），
不写代码。硬纪律：
- 空气质量是新独立链路，失败不得影响天气主屏（独立 Result）
- AQI 默认美标 us_aqi 着色，欧标并列展示
- WeatherSnapshot/共享容器加字段必须全可选+合成 Codable（旧缓存解码不失败）
- Core/ 目录禁 UIKit/try!/fatalError，被 App+Widget 两 target 同时编译
- 零第三方依赖；iOS 17.0 部署目标
```

设计产出后，同一会话让 AI 继续实现（它已有上下文），完成后你 push 验证 CI。

### 路线 B：你自己直接写（不依赖 AI）

看 `docs/handover/PRD-zhisheng-ios-A.md` A2 表格直接动手，架构决策参考 §4.1 的技术情报，代码风格跟着现有文件抄（中文注释 + docstrings + 类型注解）。

### 4.3 无论哪条路线，这 8 条硬纪律碰了必返工

1. **共享容器加字段 = 全可选 + 合成 Codable**。禁 payloadVersion、禁手写 `init(from:)`。旧 JSON 解码不失败是生死线（有专项测试 `WeatherSnapshotCacheCompatTests` 锁着）。
2. **`Core/` 目录**：禁 `import UIKit`/`UIApplication`/`try!`/`fatalError`；它被 App 和 Widget **两个 target 同时编译**——Core 里的文件**不能引用**只在单 target 存在的符号（CI run9 实测 1 小时坑）。
3. **Widget 零网络零写入**：小组件进程禁 URLSession、禁写共享容器。数据永远主 App 写。
4. **`supportedFamilies` 只增不减**，`kind` 字符串逐字不动（动了已有组件会被系统移除）。
5. **`@Observable` 类的观察用 `onChange(of:)`**，它没有 `$` 投影（那是 ObservableObject 机制，CI run10 实测）。
6. **测试期望值先独立复算再写死**（CI run12 实测：epoch 手算错 31 天、Calendar 对 13 月是溢出不是 nil）。
7. **View 结构体整体标 `@MainActor`**；`@MainActor` 类不能作非隔离 default 参数。
8. 每批结束 `bash qa-static-check.sh` 必须全绿再 push（41 项静态纪律，新增判据往脚本里加）。

---

## 5. iPhone 侧（自签安装，与开发机无关）

1. 从 Actions 最新绿 run 下载 `ZhishengWeather-unsigned-ipa` artifact 并解压（zip 里是 .ipa）
2. Windows 时代用 Sideloadly + 数据线。Linux 云电脑可用 **AltStore/侧载工具**或回到任意有 iTunes 的机器用 Sideloadly——**签名工具链与开发环境无关**，你在哪台机器签都行
3. 签名前提（没做过的话）：付费开发者账号 → App Groups 注册 `group.com.zhisheng.weather` → 两个 App ID（`com.zhisheng.weather` + `.widget`）都勾选该 group → Profile 包含 App Group → 重签名保留 entitlements
4. **A1 批次真机验收 4 项**（还没验）：①锁屏组件 AOD 熄屏可读；②**覆盖安装**后旧缓存正常；③已添加桌面组件未被移除；④Medium/Large 右上角刷新按钮拉起主 App 强刷

---

## 6. 本次交接的状态快照（2026-09-11）

- 最后 commit：`7f569ef`（已 push 且 CI run13 SUCCESS，远端=本地）
- 本地工作树：干净，无未提交改动
- 本机 Windows 独有、**不会带走**的东西：git credential store 里的 PAT（重新生成）、代理 7897（ irrelevant，云电脑用自己的出网）、WorkBuddy 会话与专家团（用 §4 路线替代）
- 随仓库带走的一切：全部代码、全部文档（docs/handover/ 新增 7 份）、CI 配置、踩坑记录 `docs/CI-pitfalls.md`
- 遗留待办：A2 开工（材料齐）、A1 真机验收 4 项（用户侧）、`CityListView` 的 showSearch 聚焦增强（留了一行接口，真机反馈后再接）

## 7. 万一出新机器后的第一个问题清单

| 症状 | 处置 |
|---|---|
| push 报 GH007 email privacy | §2.2 的 noreply 邮箱没配 |
| push 反复要密码 | PAT 要用 token 不是账号密码；确认 credential.helper store 生效 |
| CI 红在 "future Xcode project format (77)" | 有人改了 XcodeGen 安装方式，必须回滚到锁定的 2.42.0 下载方案 |
| CI 红在 cannot find X in scope | 违反 §4.3-2，双 target 编译文件引用了单 target 符号 |
| CI 红在 Test Case failed 但本地静态检查全绿 | 正常，逻辑断言只能 CI 暴露；把日志 error 行贴给 AI 修 |
| qa-static-check.sh 报 FAIL | 按 FAIL 行的判据说明改代码，不要改脚本放水 |
| curl GitHub 超时 | §2.4 配代理 |
