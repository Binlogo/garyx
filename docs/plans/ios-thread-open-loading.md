# iOS 进入线程 loading 过久 — 修复(as-built v4)

> 经过两轮方案评审(#TASK-2711)和一轮代码评审(#TASK-2712)。v1 的 policy 拆分、
> v2/v3 的若干表述均已被推翻并修正。本文记录**实际实现**。
> 引用一律用文件名 + 符号名,不用会腐烂的行号。

## 症状

进入一个已有线程,消息区 skeleton 转数秒,结束时内容和进入前一致。

## 根因

**磁盘 auto-hydrate 与专用 cold-open restore 竞速;前者写入 mirror 并推进 generation
(可能让后者被 freshness policy 丢弃),而前者又不发布 UI 变化。**

不是"单纯漏了一个通知" —— 竞态是因果链的一部分,而 policy 行为本身符合 TASK-1751 设计。

1. 读取侧早已接好:`renderSnapshot(for:)` 回退读 mirror;
   `isSelectedThreadAwaitingInitialHistory` 已把 mirror 当 `cachedTranscript`;
   mapper 用 mirror 的 messages 解析 ref。
2. `transcriptSnapshotAsync` 磁盘命中即 seed mirror,且 stream
   (`selectedThreadStreamRequestForActor`)与 history
   (`fetchThreadTranscriptIncrementally` → `transcriptAfterCursorAsync`)**都在发网络前**
   await 它 —— happens-before 本就成立,无需重排。
3. 但 `transcriptMirror` 不是 `@Published`,`setTranscriptMirror` 也不发
   `objectWillChange`。**这是有意的**:直播期间每条 committed message 都写它。
4. 于是磁盘快照静默进内存,视图不知道,skeleton 继续转,直到某个**别的** `@Published`
   写入顺带 invalidate。(源码只能确认"history 完成必有一个晚期 publish";`messages`
   自身也是 `@Published`,SSE 的 `setRenderSnapshot` 也可能先到。究竟谁先解锁
   **未经运行时验证**,不做断言。)

净效果:等一次网络往返,换回一屏几毫秒前就已在内存里的内容。

## 实现

一处改动:把"磁盘 auto-seed"升级为**可见 hydrate**,并补齐它欠缺的新鲜度与 floor 锚定。
行为入口集中在 `GaryxMobileModel+TranscriptCache.swift::transcriptSnapshotAsync`
(另在 `GaryxMobileModel.swift` 新增两处状态:发布用的 revision 和 in-flight 表)。

1. **并发合并**。mirror 检查发生在 await 之前,冷开时 stream 和 history 会同时穿过;
   不合并则各读一次盘、各 seed 一次、各推进一次 generation。
   共享任务承载 load → 新鲜度判定 → hydrate,但**不冻结任何人的返回值**:
   entrant 可能在共享工作完成很久之后才恢复(hydrate 之后排队的 clear、或整个
   gateway scope 已被离开),所以每个 entrant 在 await 前捕获自己的 token,恢复后
   复检 token 并**重新读一次 mirror**(`resolvedTranscriptWindow`)。
   token 失配返回 nil —— thread id 在不同 gateway 之间可能重名,把 destination scope
   的窗口交给 origin entrant 会把另一个后端的 `afterCursor` 喂进它的 stream/history 请求。
   in-flight 表的清理是 identity-checked,不会清掉后来者装入的条目。
2. **await 后双重新鲜度复检**(`finishTranscriptDiskHydration`,主 actor 上一步完成,
   判定不跨挂起):
   - `capturedGeneration`:覆盖加载期间的任何 mirror 变更,**包括 nil clear**。
     `clearTranscriptCache` 把 mirror 清成 absent,"有没有东西在那"式的检查看不见它 ——
     这正是 TASK-1751 P1 的 generation 存在的意义。
   - `capturedToken`(`gatewayRequestToken`):覆盖 gateway 切换。切换整体丢弃 mirror,
     而 `GaryxTranscriptMirrorStore.clearAll` **只给已存在的线程**递增 generation ——
     首次冷 hydrate 的线程本就不在 mirror 里,generation 救不了,只有 scope token 能
     判断这份解码结果属于已离开的 scope。
3. **hydrate 事务**(`hydrateTranscriptMirrorFromDisk`):seed mirror → **若不是当前
   选中线程则到此为止**(不锁 floor、不发布);是选中线程时,窗口带 render snapshot 则
   `lockSelectedTurnRowsWindowFloorIfNeeded()`,然后递增专用 revision。

`GaryxMobileModel.swift`:新增 `@Published transcriptMirrorHydrationRevision`
(与既有 `selectedTurnRowsWindowRevision` 同样式,internal setter)+ in-flight 表。

**floor 锚定不可省。** 专用 cold restore 经 `setRenderSnapshot` 会锁 floor;纯 getter 会算出
最新 60 行却丢弃 resolved floor,活跃 run 追加尾行时可见 suffix 就会滑动(违反 TASK-1751 P3)。
实测:不锁 floor 时追加 5 轮,头部从 `turn:21` 滑到 `turn:31`。

**发布次数:典型 hydrate 发出两次 `objectWillChange`** —— floor lock 推进
`selectedTurnRowsWindowRevision`,hydrate 再推进自己的 revision,同一 tick 内。
"发布一次"仅指专用 revision。

**只有 auto-hydrate 会为一次 mirror seed 额外推进 hydration revision**;直播 mirror 写
保持静默(`hydrateTranscriptMirrorFromDisk` 只有磁盘命中一个调用点;SSE 的
committed/render 写继续走普通 setter)。专用 cold restore 本就通过 `setRenderSnapshot`
发布,不受影响。

## 为什么不写 `renderSnapshotsByThread`

会让 `GaryxColdOpenRestorePolicy.State.hasRenderSnapshot` 变 true,而 `shouldApply` 和
`shouldSeedMirror` 都要求 `!hasRenderSnapshot`。存在真实可达时序:stream hydrate 先完成、
cold restore 后 spawn —— 当前实现下 restore 捕获的是已推进的 generation,**仍可恢复
messages**;写进权威通道则会被永久挡掉。

## 准确的影响表述

**不引入新的 render authority;有意提前暴露既有的 server-owned 缓存快照。**

可达时间线**确实变了**:原先某些竞态是 `skeleton → 网络内容`,现在是
`skeleton → 缓存内容 → 实时内容`,陈旧缓存的可见时长从零变为"直到网络返回"。
TTL 24h 封顶,首帧实时快照覆盖自愈。

## 验证

`Tests/GaryxMobileTests/GaryxTranscriptDiskHydrationPublishTests.swift`,15 例。
**加载期间**的竞态用例(直播写入、nil-clear、gateway 切换)用真实 happens-before:
gated fake store 在 `load` 内阻塞(跑在主 actor 之外),测试在主 actor 完成变更后才放行,
不依赖 `Task` 调度顺序;进入通知用带超时的 `XCTestExpectation`,回归不会挂死 suite。
**完成之后**的 waiter 窗口则不经 store 直接构造(装入一个已完成的 in-flight 条目,
再 seed 并清空 mirror)。

- 新代码 **15/15 PASS**(连跑 3 次无抖动)。
- 摘掉 hydrate 事务的旧行为探针:**6 FAIL**(含发布断言、floor 滑动 `turn:21`→`turn:31`)。
- 退回单一 `if let current` 新鲜度检查的探针:**5 FAIL**(nil-clear 复活、
  gateway 切换后旧 scope 窗口复活并在后续选择时可见)。
- 摘掉 per-entrant scope 复检的探针:**1 FAIL** ——
  `testEntrantFromAnExitedScopeNeverReceivesTheDestinationScopesWindow`,
  origin entrant 收到了 destination scope 的窗口。
- "冻结共享返回值"由 `testEntrantResumingOnACompletedEntryRereadsTheMirror` 隔离固化
  (构造来自 review #TASK-2712):在 `1f6f15d44` 上 FAIL(返回冻结的旧窗口),
  在 `030f611b5` 上 PASS。
- `swift test`(GaryxMobileCore)1595 passed。
- `xcodebuild -only-testing:GaryxMobileTests` 220 passed。
- app target `xcodebuild build` SUCCEEDED。
- 新增测试文件后跑了 `xcodegen generate`(工程按目录收录;已验证引用文件集合只多了
  该文件,其余为 UUID 规范化抖动)。

### 已知测试覆盖缺口

`testHydrateLeavesColdOpenRestorePolicyStateAbleToApplyMessages` 只固化**policy 输入**
(production spawn 在那一刻会捕获的状态),没有驱动私有的、由路由回调触发的
`spawnColdOpenTranscriptRestore`,因此不断言 messages 真的落地。

## 边界

本机开过且磁盘缓存仍在(TTL 24h 内)的线程 → hydrate 落地即出内容;**P4 内存淘汰过的
线程同样受益**,因为淘汰只清内存投影,磁盘缓存仍在。

从未在本机开过、或超出 TTL 的线程仍需等网络。本轮之后对服务端做了实测(localhost,
388MB / 55541 行的线程):

| | |
|---|---|
| `/api/threads/history` | 1.05s,响应仅 419KB |
| warm 重跑 | 1.14s / 1.19s —— 缓存对这条路径**完全无效** |
| 延迟 vs 文件大小 | 线性,约 2.7 ms/MB |
| 同一请求去掉 `user_query_limit` | **0.004s**(返回 100 条真实消息) |

所以慢的不是"文件大",而是 `user_query_limit` 触发 `page_before_user_queries`
从字节 0 正向扫描找最近 N 个 user turn,且绕过缓存。iOS 的分页循环每页都带这个参数
(最多 50 页),于是每翻一页重扫一次整个文件 —— 这才是多秒延迟的来源。

修法应为**从尾部倒扫**找 user turn(store 已有 64KB 反向分块机制),而不是建索引或
调缓存预算 —— 实测证明后两者对这条路径无效。次要项:剩余整文件读移入 `spawn_blocking`,
避免单个大线程占住 tokio worker。均不在本轮范围。
