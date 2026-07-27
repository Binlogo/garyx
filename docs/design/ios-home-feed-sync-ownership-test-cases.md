# iOS Home Feed Sync Ownership — E2E 测试用例

配套设计：`ios-home-feed-sync-ownership.md`
关联：#TASK-2783（复现取证，commit `dfa7d03`）
日期：2026-07-27

## 使用说明

- 本文档覆盖本需求触碰的**全部用户路径**（主 / 边界 / 出错）。
- 实现完成后**逐条实跑**，把结果写进「执行记录」列：`PASS` / `FAIL` + 证据
  （测试名与输出片段、截图路径、日志片段）。**未跑过的条目不得标 PASS。**
- 平台基线：iOS 26.5 / iPhone 17 Pro Max / **light mode only**。
- 执行方式三类：
  - **[Core]** `swift test --package-path mobile/garyx-mobile --filter <TestName>`
  - **[App]** `xcodebuild test -project GaryxMobile.xcodeproj -scheme GaryxMobile
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5'
    CODE_SIGNING_ALLOWED=NO -only-testing:<Target>/<Class>/<Test>`
  - **[真机]** 模拟器/真机走查，`idb ui tap/text` 驱动，
    `xcrun simctl io screenshot` 取证（坐标 = 截图像素 ÷ 3）
- **UI 类断言优先落成无 UI 测试**（Core 纯函数或 app-target 时序测试）；
  真机走查只用于最终确认视觉与手感，不作为唯一证据。

---

## A. 不变量（最高优先级，全部为 Core 穷举测试）

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-A1 | **骨架屏蕴含在飞** | — | 遍历**所有可构造**的 `GaryxRecentHeadPhase` | 凡派生出 `.loadingSkeleton` 的 phase，必然携带 `GaryxRecentHeadAttempt`，或该 phase 由一次产出 `.requestHead` effect 的 reduce 生成 | [Core] 穷举 | |
| TC-A2 | **无非法稳态** | — | 遍历 phase × 全部 Event 的完整矩阵 | 不存在「未 prime + 无失败 + 无在飞 + 无 pending effect」的可达终态 | [Core] 表驱动全矩阵 | |
| TC-A3 | **出厂即有义务** | — | 构造 `GaryxRecentThreadFeedState.init` | phase 为 `.primingOwed(_, .immediate)`，且初始化返回的 effect 含 `.requestHead` | [Core] | |
| TC-A4 | **清零通道必产后果** | — | 审查所有能离开 `.priming` / `.refreshing` 的路径 | 唯一出口是 `completeHead`，且其返回值非空（编译层：非 `@discardableResult`） | [Core] + 编译告警 | |
| TC-A5 | **effect 不可静默丢弃** | — | 尝试丢弃任一 mutator 返回值 | 产生编译告警 | 编译验证 | |

---

## B. 冷启动主路径

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-B1 | **冷启动无 restore** | 已配置 gateway；上次停在首页；本地有 ≥20 条线程 | 杀 app → 冷启动 | 首页在首帧显示骨架屏，数据到达后替换为列表；**全程不超过一次刷新往返** | [App] + [真机] | |
| TC-B2 | **冷启动 restore 成功**（**老板现场路径**） | 上次停在某个会话页 | 杀 app → 冷启动 → 停在恢复的会话页 → 返回首页 | 返回首页时列表**立即有数据**（不是先骨架后填充）；若返回时数据未就绪，最多一个刷新周期内出现，**绝不停在骨架** | [App] + [真机] | |
| TC-B3 | **冷启动 restore 失败** | 上次打开的线程已在服务端删除 | 杀 app → 冷启动 | 恢复失败后落到首页；列表正常加载出数据，不卡骨架 | [App] | |
| TC-B4 | **冷启动 restore 被取消** | restore 途中触发 gateway scope 切换 | 构造取消 | 首页列表仍收敛到有数据或可重试态，不卡骨架 | [App] | |
| TC-B5 | **首刷被 scope 替换打断** | favorites `gatewayScope` 初值为空，首刷飞行中被替换 | 触发 `ensureThreadFavoritesScope` 抢跑 | 打断后**自动补发**一次 head refresh；终态 `.ready` 且列表有数据 | [App] 时序测试 | |
| TC-B6 | **首刷被 identity 轮换打断** | store incarnation 在首刷飞行中轮换 | 复用 #TASK-2783 的真实 fixture | 同 TC-B5：自动补发，收敛到有数据 | [App] | |
| TC-B7 | **双 connect 交错** | 根 `.task` 与 scenePhase 同时触发 connect | 构造交错 | 先手被判定为过期时，**仍投递一次 prime 意图**；列表最终有数据 | [App] | |
| TC-B8 | **连接前置校验早退** | 令 `isCurrentConnectRefresh` 在 `.ready` 之后失败 | 构造 | 首页不得停在骨架；prime 义务由 coordinator 独立承担 | [App] | |

---

## C. 导航与生命周期

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-C1 | **抽屉 → bot → 返回**（老板的恢复动作） | 首页已有数据 | 打开抽屉 → 点 bot → 返回首页 | 列表保持有数据；返回不触发骨架闪烁 | [真机] 截图 | |
| TC-C2 | **深度 ≥3 后返回**（host LRU 驱逐） | — | 首页 → bots 总览 → bot 详情 → 会话（挂满 4 host）→ 逐级返回首页 | home host 被驱逐并重建后，列表正常；**不出现永久骨架** | [App] + [真机] | |
| TC-C3 | **首页不可见期间不死循环** | 首页已有数据 | push 到会话页停留 ≥30s → 返回 | 刷新循环在不可见期间**降频但不终止**；返回后按正常频率继续 | [App] 时序 | |
| TC-C4 | **可见性瞬时脉冲** | — | 构造 `isHomeVisible` true→false→true 落在同一渲染事务 | 循环存活（`continue` 语义），不依赖边沿复活 | [Core] planner + [App] | |
| TC-C5 | **gateway scope 切换** | 已连 gateway A | 切到 gateway B | coordinator 随 scope 重建；B 的列表正常加载；A 的在飞请求不污染 B | [App] + [真机] | |

---

## D. 前后台

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-D1 | **后台 → 前台（短）** | 首页有数据 | 切后台 5s → 回前台 | 列表刷新一次，数据更新 | [真机] | |
| TC-D2 | **后台 → 前台（长）** | 首页有数据 | 切后台 ≥5min → 回前台 | 列表刷新；不出现骨架回退 | [真机] | |
| TC-D3 | **后台期间循环挂起** | — | 切后台 | 刷新循环挂起（不空转耗电）；回前台由 scenePhase 明确重启 | [App] 时序 | |
| TC-D4 | **前台化撞上冷启动 connect** | 冷启动途中立即切后台再回前台 | — | 不产生「两边都不刷」的空隙；列表最终有数据 | [App] | |

---

## E. 用户操作

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-E1 | **下拉刷新** | 首页有数据 | 下拉 | 刷新一次；期间保留旧行不闪烁 | [真机] | |
| TC-E2 | **下拉撞上在飞刷新** | 刷新在飞 | 立即下拉 | 意图**留痕并在完成后补发**，不静默丢弃 | [App] | |
| TC-E3 | **filter 切换 Chats ↔ All** | — | 反复切换 | 各 feed 各自收敛到有数据；不互相污染 | [真机] + [App] | |
| TC-E4 | **切到 Favorites 再切回** | — | Chats → Favorites → Chats | 切回后 `.nonTask` feed 有数据（对照 D11 债务：当前会永不刷新） | [App] | |
| TC-E5 | **失败态点击重试** | 令首刷网络失败 | 点「Tap to retry」 | 重新发起并成功后显示列表 | [真机] | |
| TC-E6 | **分页 load-more** | 列表 > 一页 | 滚到底 | 加载下一页；期间 head refresh 被拒后**补发** | [App] + [真机] | |
| TC-E7 | **load-more 与 head refresh 并发** | — | 翻页途中触发下拉 | 两条通道互不吞噬；最终两者都生效 | [App] | |

---

## F. 出错与边界

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-F1 | **真正的空列表** | 账号下确无线程 | 冷启动 | 显示「No recent threads」**空态**，不是骨架屏 | [App] + [真机] | |
| TC-F2 | **首刷网络失败** | gateway 返回 5xx / 超时 | 冷启动 | 显示 `.unavailable` **可点重试**，不是骨架屏 | [App] + [真机] | |
| TC-F3 | **gateway 不可达** | 关掉 gateway | 冷启动 | 落到 setup / 连接失败界面（非首页骨架） | [真机] | |
| TC-F4 | **已 prime 后刷新失败** | 列表有数据 | 令下次刷新失败 | **保留旧行** + 顶部失败提示；绝不清空成骨架 | [App] + [真机] | |
| TC-F5 | **骨架超时降级**（若采纳 3.7） | 令 prime 永不收敛 | 等待 N 秒 | 骨架降级为可点重试态 | [App] | |
| TC-F6 | **弱网慢响应** | 注入 3s 延迟 | 冷启动 | 骨架屏期间确有请求在飞（不变量 TC-A1 在真实链路成立）；数据到达后正常 | [真机] + 日志 | |

---

## G. 回归契约（#TASK-2783 交付的失败测试）

以下三个测试当前**必挂**，修复后**必须全绿**，且**不得通过修改断言来转绿**：

| # | 测试 | 当前失败信息要点 | 执行记录 |
|---|---|---|---|
| TC-G1 | `GaryxHomeThreadListPagerTests.testColdStartIdentityInterruptCannotLeaveIdleFeedPresentedAsLoading` | 「无请求在飞却仍投影 loadingSkeleton(6)」 | |
| TC-G2 | `GaryxHomeThreadListRefreshCommitTests.testColdStartRecentIdentityInterruptionSchedulesAReplacementRefresh` | 「placeholder=loadingSkeleton, isRefreshingHead=false, recentRequests=1, 无 replacement」 | |
| TC-G3 | `GaryxHomeThreadListRefreshCommitTests.testColdStartFavoritesIdentityResetSchedulesAReplacementRefresh` | 「reset 前后 recentRequests 均为 2，无 replacement」 | |

---

## H. 既有测试改写核对

设计文档第 7 节列出的 9 条「把错误行为固化成契约」的测试，**逐条改写**（不得删除了事）。
每条需记录：改写后的断言是什么、为什么新断言表达的是正确契约。

| # | 测试 | 改写后断言 | 执行记录 |
|---|---|---|---|
| TC-H1 | `GaryxHomeThreadListPagerTests.swift:329-343` | | |
| TC-H2 | `GaryxRecentThreadFeedsTests.swift:62-73` | | |
| TC-H3 | `GaryxRecentThreadFeedsTests.swift:92-101` | | |
| TC-H4 | `GaryxLastOpenedThreadRestorationPolicyTests.swift:56-74` | | |
| TC-H5 | `HomeProjectionActorTests.swift:108-140` | | |
| TC-H6 | `HomeProjectionActorTests.swift:103` | | |
| TC-H7 | `GaryxRecentThreadFeedsTests.swift:23-34` | | |
| TC-H8 | `GaryxHomeThreadListRefreshCommitTests.swift:767` | | |
| TC-H9 | `GaryxHomeThreadListRefreshCommitTests.swift:1010-1072` | | |

---

## 覆盖自查

- 冷启动全部收敛分支：TC-B1..B8 ✅
- 导航与 host 生命周期：TC-C1..C5 ✅
- 前后台：TC-D1..D4 ✅
- 用户可发起的每个刷新入口：TC-E1..E7 ✅
- 出错与空态（骨架 / 空态 / 失败态三者可区分）：TC-F1..F6 ✅
- 不变量穷举：TC-A1..A5 ✅
- 回归契约：TC-G1..G3 ✅
- 既有错误契约改写：TC-H1..H9 ✅
