# iOS Home Feed Sync Ownership

状态：设计中（待实现）
关联：#TASK-2783（复现取证）
作者：Gary
日期：2026-07-27

## 1. 现象与定性

### 1.1 用户报告

杀掉 iOS app 后冷启动，首页（pinned + recent 线程列表）永久停在 loading 骨架屏，永远不更新。
打开侧边栏抽屉进入任一 bot 页面、再退回首页，列表立刻出现。

### 1.2 一句话定性

> 首页「该不该有数据」这件事，被建模成了**一个异步投影出来的 UI 电平的边沿信号**。
> 消费方同时用**边沿**启动它（`.task(id:)` 仅在值跳变时重启）、用**电平采样**终止它
> （`guard … else { return }`，在 sleep 醒来那一刻读一次）。
> 电平采样杀死 + 边沿唤醒 = lost wakeup：循环自杀后电平自行恢复，但恢复过程被投影层
> 合并成「无净变化」，于是没有任何边沿可以复活它。

这不是「`recentPlaceholder` 少判了一个 bool」。真正的缺陷是：**这套状态机从未把「取头页
的义务」建模为状态**，只建模了「内容有没有」和「通道占没占用」。

### 1.3 三层叠加的缺陷

**第一层 — 非法稳态是出厂状态。**

`recentPlaceholder`（`GaryxHomeThreadListPresentation.swift:307-315`）：

```swift
guard sections.recent.isEmpty else { return .none }
if !recentFeedPresentation.isPrimed {
    return recentFeedPresentation.headFailure ? .unavailable : .loadingSkeleton(rowCount: 6)  // 生效
}
return isLoadingThreads ? .loadingSkeleton(rowCount: 6) : .empty                              // 死代码
```

正确的判据 `showsInitialSkeleton = !isPrimed && isRefreshingHead && !headFailure`
（`GaryxRecentThreadFeeds.swift:54-56`）已经算出、已经一路投影传到这个函数手里，却只用在
第 314 行——而能走到该行必然 `isPrimed == true`，该表达式恒为 false。**两套真相源并存，
生效的是错的那套。**

后果：`(isPrimed=0, headFailure=0, isRefreshingHead=0)` 是**可达 + 稳态 + 显示 loading +
无任何请求在飞**的非法组合，且它正是 `GaryxRecentThreadFeedState.init`
（`GaryxRecentThreadFeeds.swift:197-210`）的**出厂状态**。初始态本身即非法，全靠外部有人
及时发请求来遮掩。

**第二层 — 「谁补刀」不是状态机属性，是 App 层手抄约定。**

三条路径能把系统放回该非法态，且都不安排任何后续动作：

| 路径 | 位置 | 写 headFailure | 补刀 |
|---|---|---|---|
| `interruptRefresh` | `GaryxRecentThreadFeeds.swift:361-363` → `GaryxHomeThreadListPager.swift:300-303` | 否 | **无** |
| `resetFeedData` | `GaryxRecentThreadFeeds.swift:464-477` | 否（清零） | **5 个调用点中 4 个无** |
| `.abandonedStaleEpoch` | `GaryxHomeThreadListPager.swift:225/271` | 否 | **无** |

对照：`.abandonedLocalMutation` 与 `.forceReplacement` 有补刀
（`GaryxMobileModel+ThreadList.swift:107-124`），但那是 App 层重复 6 次的手抄约定，
**已经破了 2 次**（`:527-532` 两个 case 明确不跟进）。

`GaryxHomeThreadListPager.swift:298-299` 的注释自己写了义务
（*"the current domain will reissue"*），但全仓找不到任何履行者——三个调用点之后紧跟
`return`。**同一 codebase 的孪生域做对了**：favorites 域遇到同类事件时
`GaryxFavoritesState.swift:342-343` 返回 `(.scopeClear, requestSnapshot())`，把「再发一次」
作为 effect 返回。同一事件，两个域，一个自愈一个不自愈。

**第三层 — 三个「唯一一次机会」串联，无一有兜底。**

1. **冷启动首刷只发一次**（`GaryxMobileModel+Gateway.swift:581`），前面串了 5 道静默
   `return` 闸门。其中 `:572` 与 `:577` 位于 `connectionState = .ready`（`:568`）**之后**
   ——即 Shell 已挂载、骨架屏已显示、而首刷根本没发出。
2. **10 秒兜底循环用 `guard … else { return }` 而非 `continue`**
   （`GaryxMobileSidebarViews.swift:626, 630`）。任何一次延时采样为 false 即永久终止。
3. **scenePhase 热恢复兜底在冷启动显式弃权。**
   `GaryxForegroundSyncPlan.swift:40-43` 注释明文：*"A connect is already in flight; don't
   kick a second one. Its completion path handles routing/refresh."* 而「它的完成路径」正是
   第 1 条那 5 道闸门。热恢复有无条件兜底刷新（`+Gateway.swift:439`
   `forceReplacement: true`），冷启动没有。

### 1.4 证据状态（#TASK-2783 三轮取证）

**已证实（有必挂测试）**

- **非法稳态真实存在、可达、且是出厂状态。** `(isPrimed=0, headFailure=0,
  isRefreshingHead=0)` 渲染为骨架屏且无任何请求在飞；它同时是
  `GaryxRecentThreadFeedState.init` 的初始值。
- **两条 identity 路径能到达该稳态**（recent 被 `.scopeClear` 打断、favorites 快照迟到
  reset 已 primed 的 recent），均**无补刀**。二者都需要 store incarnation 轮换。
- **`.abandonedStaleEpoch` 与 identity interruption 确认无直接补刷**（穷举表已交付）。
- **`isLoadingMore` 无泄漏窗口**（穷举表已交付）。

**已推翻（记录在案，避免后人重走）**

| 假设 | 推翻证据 |
|---|---|
| 冷启动 favorites `gatewayScope` 从 `""` 被替换，与首刷形成竞态 | `GaryxMobileModel.init` 在**返回前同步**完成 `loadGatewayScopedUserState → replaceGatewayScope`；不存在「首刷已发出、scope 才替换」的窗口。legacy-only UserDefaults 的确定性时序测试通过 |
| 恢复上次会话导致首页 `.task` 以 `false` 武装而自杀 | 实测循环**正常武装**（`visible=true`）；且恢复流程**自身先刷新并 primed**，之后 `connectAndRefresh` 还会无条件再刷一次；`false` 状态持续整个会话页，不是未被观测的瞬时脉冲 |
| `.task(id:)` 与 loop guard 读到不同步的两个真相源 | `presentationSnapshot.isHomeVisible` 逐字转发 `snapshot.isHomeVisible`，同一时刻恒等 |

**新发现（改变了对现象的解释）**

- **「点 bot 再退回来就好」可能不是 `.task` 重武装。** `openBotGroup` 对携带
  `mainThreadId` / `defaultOpenThreadId` 的 bot 会走 `openThread` → 冷缓存未命中 →
  push 占位会话 → **直接补发 `refreshThreads(.userAction)`**。当前 catalog 中 5 个 bot
  有 3 个属于这一类。已有测试证明：冷 Home 骨架屏 → `openBotGroup` → 两次真实 recent
  请求 → 返回首页即 `.none`。
- **冷启动存在「首刷被吞 → 等 10 秒下一轮」的窗口**：0.3s 那次 head refresh 可能因
  自动分页的 load-more 在飞而返回 nil，下一次机会在 10 秒后。

**仍未定**

现场（无 store 轮换条件下）的真实永久触发器**尚未复现**。三轮取证共推翻 4 条假设。

> **这对本设计意味着什么**：结构缺陷本身已被证据充分证实，与现场触发器是否查明无关——
> 非法稳态可达、且是出厂状态，这本身就必须修。但**不得声称本次重构一定能修好用户报告的
> 那一次**：若该现象另有成因（例如债务清单 D1 的投影事务泄漏导致首页投影冻结），
> 需独立处理。开工前应向报告人确认现场细节（等待时长、所点 bot 的类型）。


### 1.5 为什么「切页面回来就好」

两条通道，都绕过了坏掉的机制：

1. `isHomeVisible` 的 false→true 电平跳变被某次 body 求值观测到 → `.task(id:)` 重新武装；
2. 路由深度 ≥2 时 home host 被 LRU 驱逐（`GaryxRouteStackContainer.swift:164, 1517-1559`），
   pop 回来时是**全新的 UIHostingController** → `.task` 以当时电平重新武装。

第二次刷新时 scope/identity 已一致，不再被打断，于是「立刻就好」。

## 2. 设计目标

一条不变量，一切服从它：

> **UI 显示 loading ⟺ 确有一次取头页的请求在飞，或已排队且必然被发出。**

推论目标：

- **G1** 「欠一次刷新」升格为一等状态，可被穷举、可被测试、不可被无声丢弃。
- **G2** 单一 owner。生命周期挂在 gateway 连接 scope 上，不挂 UI 可见性。
- **G3** UI 可见性降级为**节流输入**（决定刷新频率），不再是武装开关或终止条件。
- **G4** 「显示 loading 但没人在跑」在**类型层不可表达**，而非靠调用方自觉。
- **G5** 纯函数核，SwiftPM 可测，无 IO / 无 Combine / 无 Task。

## 3. 方案

### 3.1 显式状态机（Core，纯函数）

以显式 phase 取代散落的 5 个布尔。刻意**没有**「未 prime 且空闲」这个 case。

```swift
/// 头部通道停摆的原因（决定谁欠这次重发）。
public enum GaryxRecentHeadStall: Equatable, Sendable {
    case networkFailure         // 今天的 failRefresh
    case interrupted            // 今天的 interruptRefresh
    case supersededByReset      // 今天的 abandonedStaleEpoch / resetFeedData
    case identityReplacement    // storeIncarnation / serverBootId 变更
    case racedLocalMutation     // 今天的 abandonedLocalMutation
}

/// 未偿义务的归属。没有「无人」这个 case。
public enum GaryxRecentHeadDemand: Equatable, Sendable {
    case immediate              // 状态机自己要求立刻重发，effect 已发出
    case userAction             // 只有用户显式动作能重新武装
}

/// 在飞凭证。private init：只有 requestHead() 能铸造，只有 completeHead() 能消费。
public struct GaryxRecentHeadAttempt: Equatable, Sendable {
    fileprivate let epoch: UInt64
    fileprivate let seq: UInt64
    fileprivate init(epoch: UInt64, seq: UInt64) { … }
}

public enum GaryxRecentHeadPhase: Equatable, Sendable {
    case priming(GaryxRecentHeadAttempt)                          // 未提交头页，请求在飞
    case primingOwed(GaryxRecentHeadStall, GaryxRecentHeadDemand) // 未提交，欠一次
    case ready                                                    // 已提交，通道空闲
    case refreshing(GaryxRecentHeadAttempt)                       // 已提交，刷新在飞
    case readyStale(GaryxRecentHeadStall, GaryxRecentHeadDemand)  // 已提交，末次失败
}
```

| case | 进入条件 | 离开条件 |
|---|---|---|
| `.priming(attempt)` | 从 `.primingOwed` 发出 ticket；**init 即必然发出首个 ticket** | 成功 → `.ready`；失败/打断 → `.primingOwed` |
| `.primingOwed(_, .immediate)` | reset / interrupted / superseded / identityReplacement / racedLocalMutation 且未 prime | 发出 ticket → `.priming` |
| `.primingOwed(_, .userAction)` | `networkFailure` 且未 prime（今天的 `headFailure`） | 用户重试 / 下拉 → `.priming` |
| `.ready` | `completeHead` 成功提交 | `requestHead` → `.refreshing` |
| `.refreshing(attempt)` | 从 `.ready` / `.readyStale` 发 ticket | 成功 → `.ready`；否则 → `.readyStale` |
| `.readyStale(_, demand)` | 已 prime 时的任一 stall | 发出 ticket → `.refreshing` |

展示派生变成全函数，且不再看内容：

```swift
switch (phase, rows.isEmpty) {
case (_, false):                          return .none
case (.priming, _), (.refreshing, _):     return .loadingSkeleton(6)
case (.primingOwed(_, .immediate), _):    return .loadingSkeleton(6)
case (.primingOwed(_, .userAction), _):   return .unavailable
case (.ready, _):                         return .empty
case (.readyStale(_, let d), _):          return d == .userAction ? .unavailable : .loadingSkeleton(6)
}
```

**同时删除 `isLoadingThreads`**（`GaryxMobileModel.swift:160`、`Presentation.swift:251/302`、
`HomeProjectionActor.swift:11/104-106`、`HomeProjectionReducer.swift:45/75/209-218`）：
一个真相只准有一份拷贝。

### 3.2 Effect 不可丢弃

合并完成漏斗：删除独立的 `failRefresh` / `interruptRefresh` / 三种 `.abandoned*` 分叉，
统一为 `completeHead(_ ticket:, _ result: HeadResult)`，
`HeadResult = .page(bundle) | .failed(Error) | .interrupted(Stall)`。

> 今天「能把 `isRefreshingHead` 清零却不产生任何后果」的方法有 3 个
> （`Pager.swift:291/300/341`）。重构后是 **0 个**——清零的唯一途径是 `completeHead`，
> 而它必然返回 effect。

所有 mutator 返回 `[GaryxRecentFeedEffect]`，**不加 `@discardableResult`**（丢弃即编译告警），
由唯一执行器 `runRecentFeedEffects(_:)` 消费。这是复用本仓已验证的形状：
`GaryxFavoritesState.swift:318-344` + `GaryxMobileModel+ThreadFavorites.swift:106-218`。

`resetFeedData()` 与 `GaryxRecentThreadFeedState.init` 一律进入
`.primingOwed(.supersededByReset, .immediate)` 并在返回值里带 `.requestHead`
——**杜绝「初始态即非法态」**。

### 3.3 单一 owner：`GaryxHomeFeedSyncCoordinator`

`@MainActor`，model 层，成为 home recent feed 的**唯一**刷新发起者。

**生命周期挂 gateway runtime scope**，不挂 UI：scope 标识已存在
（`gatewayRequestToken` / `currentGatewayRuntimeIdentity`，`+Gateway.swift:113-119`）；
scope 建立 ⇒ coordinator 存在，scope 轮换 ⇒ coordinator 重建。这与既有的
`resetGatewayRuntimeState`（`+Gateway.swift:177-298`）边界完全对齐，不新造生命周期概念。

纯函数决策核放 Core（同风格先例：`GaryxForegroundSyncPlan`、
`GaryxBackgroundCommittedRunReconcilePlanner`）：

```swift
GaryxHomeFeedSyncPlanner.next(
    state:      GaryxHomeFeedSyncState,
    demand:     GaryxHomeFeedDemand,      // phase + pendingUserIntent
    visibility: .foregroundVisible | .foregroundHidden | .background,
    connection: .ready | .checking | .down,
    now:        Date
) -> GaryxHomeFeedSyncAction              // .none | .refreshNow(reason) | .sleep(until:)
```

各层新职责：

- **view**：只提交**用户意图**（下拉、filter 切换、重试行），不再拥有任何循环。
- **连接层**：`connectAndRefresh` 只负责建连并通知 coordinator「scope ready」，不再自己调
  `refreshThreads`。这样 `:562/:572/:577/:584` 的早退**结构上不可能**吞掉首帧数据。
- **model 后台 reconcile 循环**：交还列表刷新职责，只保留 run-state hydration
  （`+ThreadList.swift:957-974`）。

### 3.4 可见性只做节流

| visibility | 行为 |
|---|---|
| `.foregroundVisible` | 10s 轮询（维持现状） |
| `.foregroundHidden` | 降频（60s）或 0，由 planner 决定，**循环不死** |
| `.background` | 挂起；唯一允许停循环的输入，由 scenePhase 明确重启 |

**硬规则**：循环体只用 `while` + `continue`，**禁止 `guard … else { return }`**。
终止只由 `Task.isCancelled` 决定（视图真正消失）。

`.task(id:)` 的 id 改用**单调递增 epoch**（`homeRefreshArmingEpoch`），由明确的重新武装事件
（gateway scope 切换、host 重建、用户下拉）递增，**不再用会自愈翻转的业务电平**。

可见性统一取 model 实时值 `isHomeVisible`（`+Navigation.swift:114-116`）；
`homeListStore.snapshot.isHomeVisible` 退回**纯渲染输入**，不再作为任何控制信号。

### 3.5 单飞门补 trailing-edge

`GaryxHomeThreadListPager.requestHead` 被拒时记 `pendingHeadRequested`，在当前请求完成时
自动补发一次。消灭「被静默吞掉且无人补」的最后一类。

### 3.6 favorites 去分叉

favorites 今天伪造一个 recent feed 的展示三元组接入
（`GaryxRecentThreadFeeds.swift:552` 硬编码 `isPrimed: true`、
`GaryxThreadMembershipProviders.swift:125` 再编码一次、App 层
`+ThreadFavorites.swift:10-20` 用扩展遮蔽纠正）——真相源被下游打补丁。

定义共同协议，两域各自提供**真实的 phase**：

```swift
public protocol GaryxRecentHeadDomain {
    var headPhase: GaryxRecentHeadPhase { get }
    var rows: [String] { get }
    var footerState: GaryxHomeLoadMoreFooterState { get }
}
```

删除 `?? .init(isPrimed: true)`、`?? (filter == .favorites)` 及 5 处 `isPrimed: true` 默认参数。

**这属于本需求触碰的面**：不归一就意味着新状态机仍要为 favorites 伪造一个 phase，那是妥协。
favorites 域内部同款的「欠一次但无人补」空洞
（`GaryxFavoritesMembershipProvider.swift:184-202` `requestSnapshot: false` +
`+ThreadFavorites.swift:91-96`）随统一不变量一并修复——这是同一不变量的应用，不是范围扩张。

### 3.7 最后一道防线（待确认）

`.primingOwed(_, .immediate)` 持续超过 N 秒仍未收敛 → 降级为
`.primingOwed(_, .userAction)`，UI 显示可点击的「加载失败 · 点击重试」。

前 6 条全部失效时用户仍有出路。代价是多一个用户可见状态。**默认加入，等确认。**

## 4. 结构性守卫

遵循本仓既有 typestate witness 模式（`DrainedDeleteReservation`、
`ChannelBindingsMergeAuthority`，见 `docs/agents/repository-contracts.md`）：

- `GaryxRecentHeadAttempt` 无公开构造器 ⇒ `.priming` / `.refreshing` 无法在不持有在飞凭证的
  情况下构造 ⇒ 「显示骨架屏」的两个 case 天然蕴含「确有请求在飞」。
- 第三个骨架屏 case `.primingOwed(_, .immediate)` 只能由返回 `[Effect]` 的 mutator 产生，
  effect 列表非 `@discardableResult`，丢弃即编译告警；配合唯一执行器，把「谁补刀」从 App 层
  6 处手抄约定收敛为 1 处。
- 于是不变量降级为**一个穷举 switch 就能证明**的命题，不再需要跨 6 个 App 文件人工审查。

**不使用**源码文本扫描类守卫（违反仓库铁律：架构守卫必须是结构性的）。

## 5. 影响面

**新增**

- `Sources/GaryxMobileCore/GaryxRecentHeadPhase.swift`（状态机 + 纯 reducer）
- `Sources/GaryxMobileCore/GaryxHomeFeedSyncPlanner.swift`（调度决策纯函数）
- `Tests/GaryxMobileCoreTests/GaryxRecentHeadPhaseTests.swift`
- `Tests/GaryxMobileCoreTests/GaryxHomeFeedSyncPlannerTests.swift`
- `App/GaryxMobile/GaryxMobileModel+HomeFeedSync.swift`（coordinator 宿主）

**修改**

| 文件 | 改动 |
|---|---|
| `Sources/GaryxMobileCore/GaryxRecentThreadFeeds.swift` | 5 布尔 → phase；mutator 返回 effect；`:552` 去伪造 |
| `Sources/GaryxMobileCore/GaryxHomeThreadListPager.swift` | 合并完成漏斗；attempt 凭证；trailing-edge |
| `Sources/GaryxMobileCore/GaryxHomeThreadListPresentation.swift` | `:307-315` 改 phase 派生；删 `isLoadingThreads` |
| `Sources/GaryxMobileCore/HomeProjectionActor.swift` / `HomeProjectionReducer.swift` | 删除 `isLoadingThreads` 独立输入，改为透传并派生 `headPhase` |
| `Sources/GaryxMobileCore/GaryxThreadMembershipProviders.swift` | `:125` 去伪造 |
| `App/GaryxMobile/GaryxMobileSidebarViews.swift` | 删 `:204/:244/:621-643`；`:512-520`/`:545-551` 改提交意图 |
| `App/GaryxMobile/GaryxMobileViews.swift` | `:26-35` 改意图提交 |
| `App/GaryxMobile/GaryxMobileModel+ThreadList.swift` | `refreshThreads` 收口 private/witness；`:137/215/534` 改显式状态；`:920-983` 交还列表刷新职责 |
| `App/GaryxMobile/GaryxMobileModel+Gateway.swift` | `:439/:569/:581/:590` 改 scope-ready 通知；`:406-481` 改报 visibility |
| `App/GaryxMobile/GaryxMobileModel+ThreadFavorites.swift` | 接入统一 phase 协议 |

**不改变其余语义**：`GaryxHomeThreadListStore` 及 Home projection 的排序、事务和
差分协议保持原样；`HomeProjectionActor` / `HomeProjectionReducer` 只做上表所列的
phase 输入迁移。这与 §3.1 删除第二份 `isLoadingThreads` 真相源一致。

**规模**：约 9 改 + 5 新增；核心 ~300 行纯函数 + 测试。
主要风险在**把 18 个 `refreshThreads` 调用点逐一映射成意图**——机械但需逐条判定语义，
不能批量替换。

## 6. Scope 边界

**在 scope 内**：首页 recent feed 的刷新所有权、状态机、展示派生、favorites 接入统一
phase 协议、可见性角色降级、单飞门 trailing-edge。

**明确不做**（记入 `ios-home-feed-sync-ownership-review-debt.md`，独立立项）：

| # | 债务 | 出处 |
|---|---|---|
| D1 | `HomeProjectionGateway.endTransaction` 早退不递减 `transactionDepth`，可能导致首页投影**永久冻结** | `HomeProjectionActor.swift:325-337`（置信度 0.5，需并发交错单测） |
| D2 | 第二次 `connectAndRefresh` 把已 `.ready` 打回 `.checking` ⇒ 整个 navigation shell occurrence 拆建 | `+Gateway.swift:552`；`GaryxHomeObservationStore.swift:161-167` |
| D3 | recent 快照 app 侧只写不读（本地兜底需连分页锚点一并持久化，是独立协议决策） | `+ThreadList.swift:638-674`；`GaryxMobileWidgetData.swift:137-145` |
| D4 | 路由无容器分支同步改 `path` 但不调 `applyCanonicalRouteProjection` | `GaryxProductionRouteStack.swift:434-442` |
| D5 | 根 `.task` 无 `id:`，`canConnectGateway == false` 时永久放弃且无提示 | `GaryxMobileViews.swift:125-132` |
| D6 | `hasAttemptedLastOpenedThreadRestore` 先烧后判 | `+ThreadPersistence.swift:258-259` |
| D7 | home host 会被 LRU 驱逐 ⇒ 挂在 home SwiftUI 树上的所有 `.task` 都不长命，值得专项排查 | `GaryxRouteStackContainer.swift:164, 1517-1559` |
| D8 | `.equatable()` 在 home host 上实质失效（rootView 只在 mount 时构造一次） | `GaryxProductionRouteStack.swift:710-736` vs `:917-934` |
| D9 | `shouldRefreshSidebarThreads` 为读一个 Bool 重建整个 `presentationSnapshot` | `GaryxMobileSidebarViews.swift:641-643` |
| D10 | L1/L2 单通道契约互斥（一层说 load-more 不阻塞 refresh，另一层说阻塞且静默丢弃） | `Pager.swift:174,188` vs `Feeds.swift:226` |
| D11 | favorites 选中时 `.nonTask` feed 永不刷新 | `+ThreadList.swift:42-49` |

**硬信号**：若 review 循环 ~3 轮后仍在出新 BLOCKER，或出现「是否偏离最初需求」的疑问，
立刻停下自查 scope 膨胀并上报拆分选项，不要继续迭代。

## 7. 必须改写的既有测试

这些测试把**错误行为固化成了契约**，重构时必须逐条改写（不是删除）：

| # | 测试 | 固化了什么 | 改成 |
|---|---|---|---|
| 1 | `GaryxHomeThreadListPagerTests.swift:329-343` | interrupt 后「**可以**再请求」（`XCTAssertNotNil`），不断言「**有人**会请求」 | 断言 `.primingOwed(.interrupted, .immediate)` 且 effect 含 `.requestHead` |
| 2 | `GaryxRecentThreadFeedsTests.swift:62-73` | `resetFeedData()` 后零断言说明有人会重新加载 —— bug 本体即契约 | 断言 reset 后 phase 非空闲且 effect 已发出 |
| 3 | `GaryxRecentThreadFeedsTests.swift:92-101` | 翻页中刷新被**静默丢弃**（`XCTAssertNil`），与 L1 契约互斥 | 断言被拒意图留痕并在完成后补发 |
| 4 | `GaryxLastOpenedThreadRestorationPolicyTests.swift:56-74` | 用生产不可达的 `(isPrimed ∧ isLoadingThreads)` 组合测死分支 | 用 `.priming` 驱动；补 `.primingOwed(_, .userAction) ⇒ .unavailable` |
| 5 | `HomeProjectionActorTests.swift:108-140` | 把虚构 transition `[.loadingSkeleton, .empty]` 固化为 actor 边界契约 | 改为 `.priming → .ready` |
| 6 | `HomeProjectionActorTests.swift:103` | 把 `isLoadingThreads` 固化为 actor 独立输入字段 | 该字段删除；断言 phase |
| 7 | `GaryxRecentThreadFeedsTests.swift:23-34` | 从不挑战 favorites 的 `isPrimed: true` 谎言 | 断言 Recent feeds 无法为 favorites 合成展示态 |
| 8 | `GaryxHomeThreadListRefreshCommitTests.swift:767` | **把非法稳态直接断言为期望结果**（等价于「gateway reset 后应当永久骨架屏」） | 断言 `.primingOwed(.supersededByReset, .immediate)` |
| 9 | `GaryxHomeThreadListRefreshCommitTests.swift:1010-1072` | **把冷启动 bug 逐字复现并断言为正确** | 断言 incarnation 变更**自动**产生 prime 义务 |

共性：9 条里有 6 条把「lane 已释放 / 可以再请求」当作终点断言。整个测试套件从未表达过
「显示 loading 就必须有人在飞」这条不变量——所以它被违反三次都没人发现。

另：`runSilentSidebarRefreshLoop` 全链路**零测试覆盖**（全仓 grep 只命中生产文件本身）。

## 8. 验证计划

e2e 用例清单见 `ios-home-feed-sync-ownership-test-cases.md`，实现时逐条实跑并回写执行记录。

分层：

1. **Core 纯函数（SwiftPM）** — phase × event 全矩阵表驱动；一条**穷举式不变量测试**：
   遍历所有可构造 phase，断言 `placeholder == .loadingSkeleton ⇒ 携带 attempt 或已产出
   `.requestHead` effect`。
2. **app-target 时序测试** — 冷启动四种收敛（无 restore / restore 成功 / restore 失败 /
   restore 被取消）、scope 切换打断、双 connect 交错、host LRU 驱逐后回归。
3. **真机走查** — iOS 26.5 / iPhone 17 Pro Max / light mode，按用例文档逐条跑，截图取证。

回归契约：#TASK-2783 交付的 3 个失败测试（commit `dfa7d03`）必须全部转绿，且不得通过修改
断言的方式转绿。
