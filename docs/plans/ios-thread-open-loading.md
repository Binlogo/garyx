# iOS 进入线程 loading 过久 — 修复(as-built v3)

> v1(拆 `GaryxColdOpenRestorePolicy`)和 v2 的部分表述已被 Codex review #TASK-2711 推翻。
> 本文是**实际实现**的记录,已吸收两轮 review 的全部修正。

## 症状

进入一个已有线程,消息区 skeleton 转数秒,结束时内容和进入前一致 —— 等了半天没有可见更新。

## 根因

**磁盘 auto-hydrate 与专用 cold-open restore 竞速;前者写入 mirror 并推进 generation
(可能让后者被 freshness policy 丢弃),而前者又不发布 UI 变化。**

不是"单纯漏了一个通知":竞态是因果链的一部分,而 policy 行为本身符合 TASK-1751 设计。

分解:

1. 渲染磁盘快照所需的读取侧全部已接好 —— `renderSnapshot(for:)` 回退读 mirror
   (`GaryxMobileModel+Messages.swift:11`);`isSelectedThreadAwaitingInitialHistory`
   已把 mirror 当 `cachedTranscript` 传入(`GaryxMobileModel+Presentation.swift:272`);
   mapper 的 ref 也用 mirror 的 messages 解析(`+Messages.swift:30`)。
2. `transcriptSnapshotAsync` 在磁盘命中时 `setTranscriptMirror`
   (`GaryxMobileModel+TranscriptCache.swift`),且 stream(`+ThreadStream.swift:163`)
   与 history(`+TranscriptCache.swift:141` → `:71`)**都在发网络之前** await 它。
   happens-before 本来就成立,无需重排。
3. 但 `var transcriptMirror` 不是 `@Published`(`GaryxMobileModel.swift`),
   `setTranscriptMirror` 也不发 `objectWillChange`。**这是有意的**:直播期间每条 committed
   message 都写 mirror,全量发布会造成失效风暴。
4. 于是磁盘快照静默进内存,视图不知道,skeleton 继续转,直到某个**别的** `@Published`
   写入顺带 invalidate(源码只能确认"history 完成必有一个晚期 publish",
   `messages` 自身也是 `@Published`;究竟谁先解锁**未经运行时验证**,不做断言)。
5. 同时,这个 auto-hydrate 会推进 mirror generation,可能把专用 cold-open restore
   顶掉 —— 而 restore 才是原设计里负责"可见恢复"的路径。

净效果:等一次网络往返,换回一屏几毫秒前就已在内存里的内容。

## 实现

一处改动,把"磁盘 auto-seed"升级为**可见 hydrate**,并补齐它欠缺的 floor 锚定。

`GaryxMobileModel+TranscriptCache.swift::transcriptSnapshotAsync`:

1. **并发合并**:`transcriptDiskHydrationTasks` in-flight 表。mirror 检查发生在 await 之前,
   冷开时 stream 和 history 会同时穿过;不合并则各读一次盘、各 seed 一次、各推进一次
   generation。("每线程每会话至多一次"在 v2 文档里是错的。)
2. **await 后新鲜度复检**:直播写入或 `clearTranscriptCache`(stream control-rewrite
   恢复路径)可能在加载途中赢下 mirror,较旧的磁盘窗口不得覆盖。
3. **hydrate 事务**(`hydrateTranscriptMirrorFromDisk`):seed mirror → 若为当前选中线程
   且窗口带 render snapshot 则 `lockSelectedTurnRowsWindowFloorIfNeeded()` → 发布一次
   专用 revision。

`GaryxMobileModel.swift`:新增 `@Published var transcriptMirrorHydrationRevision`
(与既有 `selectedTurnRowsWindowRevision` 同样式,internal setter,避免跨文件 extension
写 `private(set)` 的编译错误)+ in-flight 表存储属性。

**floor 锚定不可省。** 专用 cold restore 经 `setRenderSnapshot` 会调
`lockSelectedTurnRowsWindowFloorIfNeeded`(`+Messages.swift:15`);纯 getter 会算出最新 60 行
但丢弃 resolved floor,活跃 run 追加尾行时可见 suffix 就会滑动,违反 TASK-1751 P3。
实测:不锁 floor 时追加 5 轮,头部从 `turn:21` 滑到 `turn:31`。

**只有这条磁盘路径发布,所有直播 mirror 写保持静默。**

## 为什么不用方案 B(写进 `renderSnapshotsByThread`)

会让 `GaryxColdOpenRestorePolicy.State.hasRenderSnapshot` 变 true,而 `shouldApply` 和
`shouldSeedMirror` 都要求 `!hasRenderSnapshot`。存在真实可达时序:stream hydrate 先完成、
cold restore 后 spawn(`GaryxMobileModel.swift:112` vs `+ThreadLifecycle.swift:266`)——
方案 A 下 restore 捕获的是已推进的 generation,**仍可恢复 messages**;方案 B 下会被
`hasRenderSnapshot` 永久挡掉。有测试固化这条。

(v2 里"`resolvedMessageIds` 为空会导致 unresolved""空 messages 会掐掉 spawn"两条旁证
是错的,已删除。)

## 准确的影响表述

**不引入新的 render authority;有意提前暴露既有的 server-owned 缓存快照。**

不是"不引入任何新视觉状态"——可达时间线确实变了:原先某些竞态是
`skeleton → network content`,现在是 `skeleton → cached content → live content`,
陈旧缓存的可见时长从零变为"直到网络返回"。TTL 24h 限制偏差上限,首帧实时快照覆盖自愈。

(v2 声称的"附带收益:获得 `render_floor`"已删除 —— 请求构造本就直接用 hydrate 返回的
`snapshot` 算 floor,与是否发布无关。)

## 验证

`Tests/GaryxMobileTests/GaryxTranscriptDiskHydrationPublishTests.swift`,10 例:
发布/skeleton→content(零网络)、不写实时快照通道、hydrate 先于 restore spawn 时
messages 仍可恢复、并发双入口合并为一读一 seed 一发布、加载途中直播写不被覆盖、
floor 锚定、活跃 run 追加尾行头部不滑、无 render snapshot 的窗口、非选中线程、
直播写不发布。

- 新代码 **10/10 PASS**;摘掉发布+floor lock 的旧行为探针 **6 FAIL**(含头条断言)。
- `swift test`(GaryxMobileCore)1595 passed。
- `xcodebuild -only-testing:GaryxMobileTests` 215 passed。
- app target `xcodebuild ... build` SUCCEEDED。
- 测试文件新增后跑了 `xcodegen generate`(工程按目录收录)。

## 边界

本机开过、24h 内的线程 → hydrate 落地即出内容。从未开过 / 超 TTL / 被 P4 淘汰的线程仍需
等网络 —— 那部分属于服务端全文件扫描问题(transcript 索引、`spawn_blocking`、缓存预算),
未在本轮范围内。
