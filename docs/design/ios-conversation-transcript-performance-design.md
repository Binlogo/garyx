# iOS Conversation Transcript Performance & Smooth Send Design

Status: approved for implementation (design by Gary, 2026-07-24). Implemented
by Gary personally; downstream agents only measure, reproduce, and review.

Inputs:
- Measured baseline and root-cause ranking: `#TASK-2703` report and harness
  (commit `5ea359b6d`, on the measurement branch — deliberately not merged
  into this product branch, since it carries probe wiring); retest data in
  `#TASK-2704`, final retest in `#TASK-2706`.
- Product decisions (boss, 2026-07-24 evening): send-anchoring cancelled
  (already removed in `e6e3f7760`); tool results may be stored locally and
  fetched on demand, transcript shows a label/list instead; sending must be
  smooth with the new message and thinking fully visible above the composer.

## 1. 实测基线（模拟器 iPhone 17 Pro Max / iOS 26.5，60Hz）

| 场景 | Hitch ratio | 主线程占用 | 最差帧 |
|---|---:|---:|---:|
| 静态长线程滚动 | 0.295 | 0.452 | 808 ms |
| 流式期间滚动 | **0.930** | **0.965** | 959 ms |
| 打开线程 push | 0.168 | 0.254 | 254 ms |

流式期间主线程接近饱和（0.965）——这就是"卡"的主体感来源。

根因排序（实测）：

1. **eager 60 行全量重算/布局**（结构性主因）：流式时每次根 body 更新
   重建全部 60 行。60→20 行对照：hitch −46.9%、主线程 −26.1%、最差帧
   −73.4%。
2. **`GaryxMessageListSignature` 的 Unicode 全扫描**（实现缺陷，最便宜的
   大头）：每个 delta 50.7 ms、占该场景主线程 44.0%；栈采样 444/1652
   主线程采样，热点是对每个长字段重复 `String.count` + 中/尾字符索引。
3. **工具结果 payload 常驻**：真实长线程 1716 条结果，p50 4 B、p99
   200 KiB、最大 438 KiB；**>16 KiB 的仅占 1.92% 条数却占 89.74% 字节**。
   折叠为 label 的上界：吞吐 6.98→13.94 fps、p50 帧间隔 −43.4%、签名时间
   −99.64%。
4. **push 瞬时挂载 120 行**（稳态 60）→ 开页 183–298 ms 尖峰。
5. 锚顶机制自身成本可忽略（0.023%）——撤锚顶是产品裁决，**不是性能收益**
   （诚实记录：整体主线程回收约 2.3%）。

## 2. 优化阶段（按"收益/风险"排序，逐阶段用 harness 复测）

### P0 签名成本（纯实现缺陷，零产品行为变化）
`GaryxMessageListSignature` 不再对正文做 Unicode 扫描：改为
**长度 + 稳定摘要**（`utf8.count` + 内容哈希，避免 `String.count`
与字符索引运算），并对不可变已提交消息缓存其摘要，只重算真正变化的
尾部。预期回收该场景主线程 ~40%。

### P1 工具结果外置 + 折叠展示（老板裁决方向）
- **展示**：转录内工具行默认只显示 label/摘要（工具名、状态、大小、
  行数），可展开；展开时才读取 payload。列表形态沿用现有工具行
  presentation，不新造概念。
- **存储**：payload 超过阈值（16 KiB，取自实测分布拐点）不常驻内存/
  消息体，落**本地 sidecar 存储**（SQLite/文件，按 message id + tool
  call id 寻址），按需读取；小于阈值的保持原样（p50 只有 4 B，绝大
  多数结果本来就很小）。
- **签名**：外置结果参与签名时只用「摘要（id + 字节数 + 哈希）」，
  与 P0 一致。
- **服务端契约不动**：这是纯客户端的常驻/展示策略；`render_state`
  projection 仍是唯一真相源，外置只是本地缓存层。

### P2 行级 body 隔离
行视图做成 Equatable/稳定标识，使尾部 delta 只重算尾行，不再重建全部
可见行。与 P0/P1 叠加后复测。

### P3 测量式窗口化（结构性，最后做）
**不裸换 `LazyVStack`**（估算行高破坏底部 anchor，v1 已实证）。改为
"实测高度账本 + overscan"：为已测量行记录真实高度，窗口外用真实高度
的占位，保证 `defaultScrollAnchor(.bottom)` 与 prepend 精确
`contentOffset` 契约不变。上界收益见基线的 60→20 行对照。
顺带修 P4：push 瞬时 120 行收敛到稳态窗口。

## 3. 丝滑发送规格（老板 2026-07-24 晚）

撤锚顶后的目标行为：

1. **发完消息，消息 + 左侧 thinking 完整可见于输入框上方**：底部净空按
   浮动 composer 的**实测高度 + 安全区**给足（当前只在 safeAreaInset
   之外加 24 pt 常量），确保新行与 thinking 不被玻璃 composer 边缘吃掉。
2. **新内容自然向上滚**：跟随由系统级
   `.defaultScrollAnchor(.bottom, for: .sizeChanges)` **独占**；常规
   跟随路径不再叠加程序化 `[0,40,140]ms` 三连 scrollTo 追赶链——两套
   机制同时驱动同一意图是当前"发送即抖"的直接原因。程序化滚动仅保留在
   系统锚定管不到的场景：打开线程首帧兜底、回底按钮、prepend 保位、
   可见尾部间隙 repair（保持既有边缘触发语义）。
3. **发送瞬间不抖**：以帧级探针验证发送前后 offset 序列单调、无反向
   位移、无多次程序化写入。

## 4. 验收标准

1. **harness 复测数据（每阶段必做）**：三场景 hitch ratio / 主线程占用 /
   最差帧 / p50 帧间隔，与本文第 1 节基线对比给出前后数字。目标：流式
   场景主线程占用从 0.965 降到 < 0.6、hitch ratio < 0.5；静态滚动
   hitch < 0.15。
2. **行为回归**：打开线程首帧即底、观看流式跟随、上滑浏览不被打断、
   回底按钮、历史 prepend 保位、发送后新消息+thinking 完整可见、发送
   无抖动（帧序列证据）、进线程封面契约（#TASK-2700）与 capsule 预览
   几何（#TASK-2695）无回归。
3. **SwiftPM/布局测试**全绿（真实计数）+ xcodebuild 零 error。
4. **对抗评审 100% PASS**（不同模型家族），并以真机数据复核阈值
   （基线数字来自模拟器，报告已注明需真机复跑）。
5. **老板真机验收**（铁律）：模拟器全过不等于交付完成。

## 5. Scope 边界

- 不动：服务端 render_state 契约、SSE、桌面端、底部锚定与 prepend 保位
  契约、followingTail/browsingHistory 语义。
- 不重新引入锚顶。
- 相邻既有问题记 `docs/design/ios-send-anchor-review-debt.md`。

## 6. P3 行窗口化：设计完成、实测否决、不上线（2026-07-24）

最终复测（#TASK-2706，被测 `203f5ad77`）否决了 P3 的生产接线。**收益不成立、且引入了确定性缺陷**，据此裁决：P0 / 跟随单驱动 / P2 交付，P3 的生产驱动移除（planner 与其测试保留为已完成的设计资产与后续基础）。

否决依据（全部为实测）：

1. **内容高度确定性错误**：每个折叠段固定多 14 pt（间距被重复计入：spacer 高度已含段内被吃掉的间距，外层 stack 又在 spacer 前后各加一次）。1 段 +14 pt、2 段 +28 pt，可用 fixture 稳定复现。
2. **穿越折叠区往返失真**：offset 跳变 108 pt、内容高度漂移 6608 pt、返回后离底 2016 pt（空白帧与重复行为 0，但几何不守恒）。
3. **规划↔布局反馈循环**：异常轮出现 4713 ms / 17086 ms 最差帧，伴随 1288–2955 次计划变化与 2565–5909 次布局回调；发送后 maxOffset 从 24148 跳到 65548。
4. **收益不净正**：静态滚动 hitch −49.6%、最差帧 −86%，但**主线程占用 +67%、p95 +117%**——把"少量 800 ms 巨卡顿"换成了"频繁 35 ms 卡顿"；SwiftUI 布局仍是第一热点，采样占比反而从 17.4% 升到 27.3%。
5. Push 最差帧 +70.8%。

已交付部分的实测收益（同一批测量，相对原始基线）：流式 p50 −73.9%、p95 −72.3%、最差帧 −84.0%，delta 吞吐 +77.8%；签名成本 −99.85% 且退出热点；行构建 7440 → 89。

若将来重启 P3，先解决三件事：spacer 与外层 stack 的间距归属（用 UIHostingController 布局测试钉住总高度守恒，而不是靠代数推导）、折叠状态与布局的反馈阻尼（计划变化需节流/滞回，避免每帧重规划）、以及穿越折叠区的几何守恒回归门。
