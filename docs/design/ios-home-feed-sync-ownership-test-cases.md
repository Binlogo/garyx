# iOS Home Feed Sync Ownership — E2E 测试用例

配套设计：`ios-home-feed-sync-ownership.md`
关联：#TASK-2783（复现取证，commit `dfa7d03`）
日期：2026-07-27

## 使用说明

- 本文档覆盖本需求触碰的**全部用户路径**（主 / 边界 / 出错）。
- 实现完成后**逐条实跑**，把结果写进「执行记录」列：`PASS` / `FAIL` + 证据
  （测试名与输出片段、截图路径、日志片段）。**未跑过的条目不得标 PASS。**
- 平台基线：iOS 26.5 / iPhone 17 Pro Max / **light mode only**。
- 执行方式两类：
  - **[Core]** `swift test --package-path mobile/garyx-mobile --filter <TestName>`
  - **[App 无 UI]** `xcodebuild test -project GaryxMobile.xcodeproj -scheme GaryxMobile
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5'
    CODE_SIGNING_ALLOWED=NO -only-testing:<Target>/<Class>/<Test>`
- **UI 类断言优先落成无 UI 测试**（Core 纯函数或 app-target 时序测试）；
  本轮所有 PASS 均来自上述自动化路径。没有执行或声称截图 / 人工「开 app
  看一眼」证据。

---

## A. 不变量（最高优先级，全部为 Core 穷举测试）

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-A1 | **骨架屏蕴含在飞** | — | 覆盖 production reducer 可达的 **23 个唯一 phase family**（5 stall × 2 demand × 2 owed 形态 + priming / refreshing / ready）；用穷尽 `switch` 将 enum case 映射为 key，并校验集合无缺项 / 记录无重复 | 凡派生出 `.loadingSkeleton` 的 phase，必然携带 `GaryxRecentHeadAttempt`，或该 phase 由一次产出 `.requestHead` effect 的 reduce 生成 | [Core] 穷举 | **PASS** — `GaryxRecentHeadPhaseTests.testEveryReachableSkeletonHasAttemptOrRequestEffect` 从真实 reducer transition 生成并精确校验 23 个 phase family 的 provenance；非 skeleton 分支也在同一穷举集合中，不能靠漏列规避蕴含式。 |
| TC-A2 | **无非法稳态** | — | 对 7 类合法 seed × 25 类 production event 做矩阵，并对结果执行编译穷尽的类型不变量检查 | 不存在「未 prime + 无失败 + 无在飞 + 无 pending effect」的可达终态 | [Core] 表驱动全矩阵 | **PASS** — `testPhaseEventMatrixPreservesTypeLevelOwnershipInvariant`。最终断言刻意是 typestate 的结构性证明：非法组合没有 enum case；矩阵负责证明 reducer 不逃逸该类型边界。 |
| TC-A3 | **出厂即有义务** | — | 构造 `GaryxRecentThreadFeedState.init` | phase 为 `.primingOwed(_, .immediate)`，且初始化返回的 effect 含 `.requestHead` | [Core] | **PASS** — `testBootstrapStartsOwedAndReturnsRequestEffect`。 |
| TC-A4 | **清零通道必产后果** | — | 审查所有能离开 `.priming` / `.refreshing` 的路径：`completeHead`、`reset`、`invalidate` | completion 精确产出 `.publish` / 必需的 `.requestHead`；reset / invalidate 转成显式 immediate debt，绝不清成 unknown-idle；effect 返回值非 `@discardableResult` | [Core] + 编译告警 | **PASS** — `testEveryHeadExitProducesItsRequiredConsequence` 对成功、失败、5 种中断、reset、stale completion、local mutation、identity replacement、直接 reset / invalidate 逐项断言 outcome、phase 与 effect shape。反事实令 `drainPendingHeadEffects()` 返回 `[]` 时本测试产生 7 个失败（`/tmp/task2785-a4-counterfactual-fail.log`），还原后 PASS（`/tmp/task2785-a4-restored-pass.log`）。 |
| TC-A5 | **effect 不可静默丢弃** | — | 尝试丢弃任一 mutator 返回值 | 产生编译告警 | 编译验证 | **PASS** — 独立编译探针丢弃 `resetFeedData()` 返回值，Swift 报 `result of call ... is unused`（`/tmp/task2785-effect-discard-warning.log`）。 |

---

## B. 冷启动主路径

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-B1 | **冷启动无 restore** | 已配置 gateway；上次停在首页；本地有 ≥20 条线程 | 杀 app → 冷启动 | 首页在首帧显示骨架屏，数据到达后替换为列表；**全程不超过一次刷新往返** | [App 无 UI] | **PASS** — `testColdStartMatchingCapturedIdentitiesPrimeRecentWithoutInterruption`：首帧 skeleton→ready、`refreshCycle == 1`；2 个 HTTP page read 是同一周期的 primary + bounded verification。 |
| TC-B2 | **冷启动 restore 成功** | 上次停在某个会话页 | 杀 app → 冷启动 → 停在恢复的会话页 → 返回首页 | 返回首页时列表**立即有数据**（不是先骨架后填充）；若返回时数据未就绪，最多一个刷新周期内出现，**绝不停在骨架** | [App 无 UI] | **PASS** — `testColdStartRestoreSuccessPrimesBeforePushAndManualReturnRearmsHome` 走 production restore / route pop / canonical projection；在 restore push 前已 prime，返回快照 rows 保留且 placeholder 为 `.none`。 |
| TC-B9 | **首刷被自动分页挡住** | 冷启动，列表 > 一页 | 令 0.3s 那次 head refresh 撞上在飞的 load-more | 被拒的 head refresh **立即 trailing-edge 补发**，不等 10 秒下一轮；首屏数据到达时间不受影响 | [App] 时序 | **PASS** — `testScopeOwnerTrailsAutomaticHeadImmediatelyAfterLoadMore`：load-more 释放即发 head，未推进 cadence 时钟。 |
| TC-B10 | **thread-backed bot 打开路径** | 冷启动首页尚未 primed | 打开携带 `mainThreadId`/`defaultOpenThreadId` 的 bot → 返回 | 首页数据由 coordinator 保证，**不依赖** bot 打开路径顺带补发的刷新；去掉该副作用后首页仍能自行收敛 | [App 无 UI] | **PASS** — `testHomeFeedSelfConvergesWithoutThreadBackedBotRefreshSideEffect` 用 semaphore 保持冷 head 在飞且未 prime，bot id 不在 summary / Recent cache，断言必经 point-read cache-miss 分支；bot 路径 0 个 Recent 请求，owner 独立完成恰好 primary + verification 两次读取，返回 `.none`。反事实恢复旧隐式刷新后读数变为 4、精确失败（`/tmp/task2785-b10-counterfactual-fail.log`），还原后 PASS（`/tmp/task2785-b10-restored-pass.xcresult`）。 |
| TC-B3 | **冷启动 restore 失败** | 上次打开的线程已在服务端删除 | 杀 app → 冷启动 | 恢复失败后落到首页；列表正常加载出数据，不卡骨架 | [App 无 UI] | **PASS** — `testColdStartRestoreFailureStillLoadsHomeFeed` 用 gate 保持冷 head 确实在飞且未 prime，此时对不在缓存的 restore id 执行 1 次 point-read 并返回 404；随后释放 owner，Recent 恰好完成 primary + verification 两次读取并收敛为 rows / `.ready` / `.none`。 |
| TC-B4 | **冷启动 restore 被取消** | restore 途中触发 gateway scope 切换 | 构造取消 | 首页列表仍收敛到有数据或可重试态，不卡骨架 | [App 无 UI] | **PASS** — `testColdStartRestoreCancellationStaysHomeWithRefreshGateReleased`：真实 restore task 取消后 owner 仍补发并收敛，refresh gate 释放；允许终态 ready 或显式 retry，不声称取消路径必有数据。 |
| TC-B5 | **首刷被 scope 替换打断** | favorites `gatewayScope` 初值为空，首刷飞行中被替换 | 触发 `ensureThreadFavoritesScope` 抢跑 | 打断后**自动补发**一次 head refresh；终态 `.ready` 且列表有数据 | [App] 时序测试 | **PASS** — `testGatewayScopeRebuildCancelsOldOwnerAndRejectsLateRows` + `testColdStartRecentIdentityInterruptionSchedulesAReplacementRefresh`：新 scope 自动补发，旧行被拒。 |
| TC-B6 | **首刷被 identity 轮换打断** | store incarnation 在首刷飞行中轮换 | 复用 #TASK-2783 的真实 fixture | 同 TC-B5：自动补发，收敛到有数据 | [App] | **PASS** — `testFavoritesIncarnationChangeOwnsImmediateRecentReplacement` 与两个 #TASK-2783 captured-fixture 回归均收敛到 `.ready`。 |
| TC-B7 | **双 connect 交错** | 根 `.task` 与 scenePhase 同时触发 connect | 构造交错 | 先手被判定为过期时，**仍投递一次 prime 意图**；列表最终有数据 | [App] | **PASS** — `testScopeOwnerQueuesFavoritesUntilConnectionIsReady` 构造 checking→ready→checking→ready；Favorites 1 次、Recent 1 个逻辑周期后 ready。 |
| TC-B8 | **连接前置校验早退** | 令 `isCurrentConnectRefresh` 在 `.ready` 之后失败 | 构造 | 首页不得停在骨架；prime 义务由 coordinator 独立承担 | [App 无 UI] | **PASS** — `testStalePostReadyConnectGuardCannotConsumeHomePrime` 在 `.ready` 后阻塞 production custom-agent refresh，再用 successor request id 令旧 connect 的 guard 失败；旧 caller 不清 successor，scope owner 独立收敛到 rows / `.ready`，Recent 恰好 1 个逻辑周期。 |

---

## C. 导航与生命周期

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-C1 | **抽屉 → bot → 返回**（老板的恢复动作） | 首页已有数据 | 打开抽屉 → 点 bot → 返回首页 | 列表保持有数据；返回不触发骨架闪烁 | [App 无 UI] | **PASS** — production bot/open/return 集成测试 `testHomeFeedSelfConvergesWithoutThreadBackedBotRefreshSideEffect` 直接断言 canonical return 后 rows 已就绪且 placeholder `.none`；没有声称截图证据。 |
| TC-C2 | **深度 ≥3 后返回**（host LRU 驱逐） | — | 首页 → bots 总览 → bot 详情 → 会话（挂满 4 host）→ 逐级返回首页 | home host 被驱逐并重建后，列表正常；**不出现永久骨架** | [App 无 UI] | **PASS** — `GaryxRouteStackContainerTests.testHomeFeedOwnerAndReadyRowsSurviveHomeHostEvictionAndRemount` 用真实 route container 连 push 4 层，确认 Home host 被 LRU unmount；逐级 pop 后 Home 第二次构造，rows / `.ready` / `.none` 保留且 coordinator 对象身份不变。 |
| TC-C3 | **首页不可见期间不死循环** | 首页已有数据 | push 到会话页停留 ≥30s → 返回 | 刷新循环在不可见期间**降频但不终止**；返回后按正常频率继续 | [App] 时序 | **PASS** — `testVisibleAndHiddenCadencesOnlyChangeTheDeadline` 将可见/隐藏映射为 10s/60s deadline；`testBackgroundSuspendsIntentAndVisibilityPulseCannotKillOwner` 证明 owner 身份不变且返回可继续。 |
| TC-C4 | **可见性瞬时脉冲** | — | 构造 `isHomeVisible` true→false→true 落在同一渲染事务 | 循环存活（`continue` 语义），不依赖边沿复活 | [Core] planner + [App] | **PASS** — `testVisibilityPulseNeverChangesOrConsumesDemand` + `testBackgroundSuspendsIntentAndVisibilityPulseCannotKillOwner`。 |
| TC-C5 | **gateway scope 切换** | 已连 gateway A | 切到 gateway B | coordinator 随 scope 重建；B 的列表正常加载；A 的在飞请求不污染 B | [App 无 UI] | **PASS** — `testGatewayScopeRebuildCancelsOldOwnerAndRejectsLateRows`：owner 身份更换，A late rows 被拒，B rows ready。 |

---

## D. 前后台

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-D1 | **后台 → 前台（短）** | 首页有数据 | 切后台 5s → 回前台 | 列表刷新一次，数据更新 | [App 无 UI] | **PASS** — `testShortAndLongBackgroundClassesEachRefreshOnForeground` 的第一次 background→active occurrence：后台 0 请求，前台 1 个逻辑刷新且旧行不退 skeleton。 |
| TC-D2 | **后台 → 前台（长）** | 首页有数据 | 切后台 ≥5min → 回前台 | 列表刷新；不出现骨架回退 | [App 无 UI] | **PASS** — 同一测试的第二次 occurrence。协议不读取 elapsed duration，故用两个独立 occurrence 确定性覆盖短/长类别，无 5 分钟 wall-clock sleep。 |
| TC-D3 | **后台期间循环挂起** | — | 切后台 | 刷新循环挂起（不空转耗电）；回前台由 scenePhase 明确重启 | [App] 时序 | **PASS** — `testBackgroundAndNonReadyConnectionSuspendWithoutConsumingIntent` + `testBackgroundSuspendsIntentAndVisibilityPulseCannotKillOwner`。 |
| TC-D4 | **前台化撞上冷启动 connect** | 冷启动途中立即切后台再回前台 | — | 不产生「两边都不刷」的空隙；列表最终有数据 | [App 无 UI] | **PASS** — `testForegroundDuringColdConnectLeavesPrimeOwnedUntilReady` 在 `/api/status` 闸门内确认 `.checking`，此时 background→active；owner 身份不变、0 个提前请求、immediate debt 保留，ready 后恰好 1 个逻辑周期并收敛到 rows。 |

---

## E. 用户操作

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-E1 | **下拉刷新** | 首页有数据 | 下拉 | 刷新一次；期间保留旧行不闪烁 | [App 无 UI] | **PASS** — `testUserPullDuringActiveHeadLeavesOneTrailingReplacement` 直接经 production user-pull 入口：首个 head 阻塞时 cached rows 与 `.none` 保留，下拉意图 trailing，完成后显示 refreshed rows。 |
| TC-E2 | **下拉撞上在飞刷新** | 刷新在飞 | 立即下拉 | 意图**留痕并在完成后补发**，不静默丢弃 | [App] | **PASS** — 同一测试在首个 head gate 阻塞时下拉，观察到 `.userPullToRefresh` pending，最终恰好两个完整周期。 |
| TC-E3 | **filter 切换 Chats ↔ All** | — | 反复切换 | 各 feed 各自收敛到有数据；不互相污染 | [Core] + [App 无 UI] | **PASS** — `testLateCompletionWritesTicketFilterNotCurrentSelection` + `testChatsFavoritesChatsRefreshesNonTaskOnReturn`；ticket 按所属 filter 提交。 |
| TC-E4 | **切到 Favorites 再切回** | — | Chats → Favorites → Chats | 切回后 `.nonTask` feed 有数据（对照 D11 债务：当前会永不刷新） | [App] | **PASS** — `testChatsFavoritesChatsRefreshesNonTaskOnReturn`：Favorites 期间 nonTask 0 请求，切回立即刷新出 `thread-chat-current`。 |
| TC-E5 | **失败态点击重试** | 令首刷网络失败 | 点「Tap to retry」 | 重新发起并成功后显示列表 | [Core] + [App 无 UI] | **PASS** — `testFavoritesSnapshotFailureSurfacesUnavailableAndManualRetryRecovers` + Core `testLifecycleForceReplacementThreeOutcomesAndFailedRetry`。 |
| TC-E6 | **分页 load-more** | 列表 > 一页 | 滚到底 | 加载下一页；期间 head refresh 被拒后**补发** | [Core] + [App 无 UI] | **PASS** — `testScopeOwnerTrailsAutomaticHeadImmediatelyAfterLoadMore`：tail page 保留，head 补发后顺序为 head/seed/tail。 |
| TC-E7 | **load-more 与 head refresh 并发** | — | 翻页途中触发下拉 | 两条通道互不吞噬；最终两者都生效 | [App] | **PASS** — App 时序测试 + Core `testRefreshBlockedByLoadMoreTrailsImmediatelyAfterCompletion`，两条 lane 均提交。 |

---

## F. 出错与边界

| # | 用例 | 前置 | 步骤 | 期望 | 方式 | 执行记录 |
|---|---|---|---|---|---|---|
| TC-F1 | **真正的空列表** | 账号下确无线程 | 冷启动 | 显示「No recent threads」**空态**，不是骨架屏 | [Core] + [App 无 UI] | **PASS** — Core `testEmptySuccessPrimesAndFailurePreservesCachedRows` + `testRefreshLoadingBoundaryPublishesSkeletonBeforeRefreshTransactionCompletes`：成功空页终态 `.empty`。 |
| TC-F2 | **首刷网络失败** | gateway 返回 5xx / 超时 | 冷启动 | 显示 `.unavailable` **可点重试**，不是骨架屏 | [App 无 UI] | **PASS** — `testColdStartRecentFailureStaysHomeWithUnavailableNotSkeleton` 让 `/api/recent-threads` 返回 503，断言 Home 仍可见、phase 为 `.primingOwed(.networkFailure, .userAction)`、placeholder `.unavailable`。 |
| TC-F3 | **gateway 不可达** | 关掉 gateway | 冷启动 | 落到 setup / 连接失败界面（非首页骨架） | [App 无 UI] | **PASS** — `testUnreachableGatewayPresentsSetupInsteadOfHomeSkeleton` 让 production `/api/status` 抛 `.cannotConnectToHost`，断言 connection `.failed` 且 root surface `.gatewaySetup`；即使隐藏的 Home reducer 保留 owned bootstrap skeleton，也不是可见根界面。 |
| TC-F4 | **已 prime 后刷新失败** | 列表有数据 | 令下次刷新失败 | **保留旧行** + 顶部失败提示；绝不清空成骨架 | [Core] + [App 无 UI] | **PASS** — `testEmptySuccessPrimesAndFailurePreservesCachedRows` 保留 cached IDs；`testChatsAuxiliaryFailureOnlyMarksAllFeed` 验证失败归属且不清空选中列表。 |
| TC-F5 | **骨架超时降级**（若采纳 3.7） | 令 prime 永不收敛 | 等待 N 秒 | 骨架降级为可点重试态 | [App] | **PASS** — `testImmediateDebtDowngradesToRetryAndDropsQueuedTransportAtDeadline`：N 到期转 `.primingOwed(..., .userAction)` / `.unavailable`。生产 N=5s。 |
| TC-F6 | **弱网慢响应** | 注入 3s 延迟 | 冷启动 | 骨架屏期间确有请求在飞（不变量 TC-A1 在真实链路成立）；数据到达后正常 | [App 无 UI] | **PASS** — `testThreeSecondColdHeadKeepsAttemptProofUntilRowsArrive`：真实 app transport 被闸门延迟 3s，期间 attempt 始终非 nil，随后 rows / `.ready`。 |

---

## G. 回归契约（#TASK-2783 交付的失败测试）

以下三个测试当前**必挂**，修复后**必须全绿**，且**不得通过修改断言来转绿**：

| # | 测试 | 当前失败信息要点 | 执行记录 |
|---|---|---|---|
| TC-G1 | `GaryxHomeThreadListPagerTests.testColdStartIdentityInterruptCannotLeaveIdleFeedPresentedAsLoading` | 「无请求在飞却仍投影 loadingSkeleton(6)」 | **PASS** — 原 `XCTAssertFalse` 文本未修改，但公开记录契约重述：设计 §2 / §3.1 允许 `.primingOwed(_, .immediate)` 投影 skeleton，只要该 transition 已产出必执行的 `.requestHead`。测试现驱动唯一 executor 的 effect 边界后再执行原断言；没有先 `XCTUnwrap` replacement。反事实删除 effect 后原断言在原行精确失败（`/tmp/task2785-g1-counterfactual-fail.log`），还原后 PASS（`/tmp/task2785-g1-restored-pass.log`）。 |
| TC-G2 | `GaryxHomeThreadListRefreshCommitTests.testColdStartRecentIdentityInterruptionSchedulesAReplacementRefresh` | 「placeholder=loadingSkeleton, isRefreshingHead=false, recentRequests=1, 无 replacement」 | **PASS** — 原断言未修改；replacement 自动补发。 |
| TC-G3 | `GaryxHomeThreadListRefreshCommitTests.testColdStartFavoritesIdentityResetSchedulesAReplacementRefresh` | 「reset 前后 recentRequests 均为 2，无 replacement」 | **PASS** — 原断言未修改；replacement 自动补发。 |

---

## H. 既有测试改写核对

设计文档第 7 节列出的 9 条「把错误行为固化成契约」的测试，**逐条改写**（不得删除了事）。
每条需记录：改写后的断言是什么、为什么新断言表达的是正确契约。

| # | 测试 | 改写后断言 | 执行记录 |
|---|---|---|---|
| TC-H1 | `GaryxHomeThreadListPagerTests.swift:329-343` | identity interrupt 后为 `.primingOwed(.interrupted, .immediate)`，并产出 replacement `.requestHead`；中断不是允许通道空闲。 | **PASS** — 改写为 `testIdentityInterruptProducesOwnedImmediateReplacement`，它经 `completeHead(.interrupted)` 覆盖 pager `interruptRefresh`；另加 `GaryxRecentThreadFeedsTests.testInterruptLoadMoreDrainsOwnedTrailingHeadRequest`，直接断言 `interruptLoadMore` 释放 lane 并补发 pending head。 |
| TC-H2 | `GaryxRecentThreadFeedsTests.swift:62-73` | reset 递增 epoch、保留 selection，并将 phase 置为 immediate owed，同时返回 request effect。 | **PASS** — 改写为 `testResetAbandonsOldEpochAndPreservesSelection`。 |
| TC-H3 | `GaryxRecentThreadFeedsTests.swift:92-101` | load-more 拒绝 head 时记录 pending intent；load-more completion 必须立即返回 trailing request。 | **PASS** — 改写为 `testRefreshBlockedByLoadMoreTrailsImmediatelyAfterCompletion`。 |
| TC-H4 | `GaryxLastOpenedThreadRestorationPolicyTests.swift:56-74` | 真正 priming attempt 派生 skeleton；`.userAction` owed 派生 `.unavailable`，不能把 unknown-idle 当 loading。 | **PASS** — 改写为 `testInitialEmptyLoadingSnapshotDerivesRecentSkeletonRowsInCore`。 |
| TC-H5 | `HomeProjectionActorTests.swift:108-140` | 用真实 priming→ready phase 边界断言 skeleton→empty，而不是手工布尔组合。 | **PASS** — 改写为 `testRefreshLoadingBoundaryPublishesSkeletonBeforeRefreshTransactionCompletes`。 |
| TC-H6 | `HomeProjectionActorTests.swift:103` | actor 输入/结果携带 `recentFeedPresentation.headPhase`；旧 `isLoadingThreads` 信号不再存在。 | **PASS** — `testGatewayUsesLatestBoundaryWhileActorIsInFlight` 现断言 actor 输出保留与输入**完全相同的 attempt-bearing phase**，不是只断言派生 Boolean；`testRefreshLoadingBoundaryPublishesSkeletonBeforeRefreshTransactionCompletes` 再断言 priming→ready 的 skeleton→empty。 |
| TC-H7 | `GaryxRecentThreadFeedsTests.swift:23-34` | Favorites 选择不构造 Recent pager、phase 或 transport ticket；由 Favorites provider 自有统一 phase。 | **PASS** — 改写为 `testFavoritesSelectionHasNoRecentPagerOrTransportTicket`。 |
| TC-H8 | `GaryxHomeThreadListRefreshCommitTests.swift:767` | 旧 gateway auxiliary failure 不 toast；reset 后选中 feed 为 `.primingOwed(.supersededByReset, .immediate)` 并由 owner 补发。 | **PASS** — 改写为 `testAuxiliaryFailureFromPreviousGatewayDoesNotToastAfterReset`；保留 reset 前的旧 coordinator，并用 `waitForTransportIdleForTesting()` 确定性等待旧 transport 结算，不再依赖 `Task.yield()`。 |
| TC-H9 | `GaryxHomeThreadListRefreshCommitTests.swift:1010-1072` | Favorites incarnation 变化拥有一次 immediate Recent replacement；终态 ready，旧 ticket 被拒。 | **PASS** — 改写为 `testFavoritesIncarnationChangeOwnsImmediateRecentReplacement`。 |

## 执行汇总

- 基线：iOS Simulator 26.5、iPhone 17 Pro Max、light mode。
- 本文档实际包含 **49** 条可执行记录（A 5 + B 10 + C 5 + D 4 +
  E 7 + F 6 + G 3 + H 9）；49/49 均已按上表实跑并记录。
- Core 完整集合：1636/1636 PASS。常规 1614 条：
  `/tmp/task2785-swiftpm-round2-noncrash2.log`；耗时较长且直到结束才刷新
  stdout 的 crash-harness 22 条：
  `/tmp/task2785-swiftpm-round2-crash-harness.log`。
- Home app-target 聚焦类：63/63 PASS，
  `/tmp/task2785-home-round2-final4.xcresult`。
- 完整 app-target：259/259 PASS，
  `/tmp/task2785-app-round2-final2.xcresult`。
- #TASK-2783 的 6 条判别路径均保留并通过：scope 同步初始化、Home
  visibility false→true、restore 成功/失败/取消，以及 thread-backed bot
  打开/返回。最后一条按 TC-B10 将断言从“bot 顺带刷新”升级为“owner 已自行
  收敛，bot 不产生隐藏刷新”，真实 fixture 和导航路径未删除或弱化。
- N=5s 的依据：对本地 gateway 精确冷启动 head 链路实测 100 次，
  min 9.82ms、p50 11.98ms、p95 15.21ms、p99 20.37ms、max 27.28ms；
  5s 覆盖 3s 弱网验收窗口再留约 2s 调度余量，约为实测 p99 的
  245.5 倍。原始数据：`/tmp/task2785-home-head-latency.json`。

---

## 覆盖自查

- 冷启动全部收敛分支：TC-B1..B10 ✅
- 导航与 host 生命周期：TC-C1..C5 ✅
- 前后台：TC-D1..D4 ✅
- 用户可发起的每个刷新入口：TC-E1..E7 ✅
- 出错与空态（骨架 / 空态 / 失败态三者可区分）：TC-F1..F6 ✅
- 不变量穷举：TC-A1..A5 ✅
- 回归契约：TC-G1..G3 ✅
- 既有错误契约改写：TC-H1..H9 ✅
