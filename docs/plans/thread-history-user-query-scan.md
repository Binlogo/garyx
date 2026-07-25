# `/api/threads/history` 最新用户轮次窗口:改为缓存尾部服务(as-built)

> 经过两轮方案评审(#TASK-2714)。v1 的核心前提 `index == seq - 1` 被生产导入契约
> 证伪;v2 的代价/内存表述和验证口径也被修正。本文记录**实际实现**。

## 问题

`page_before_user_queries` 的流式扫描从字节 0 走到 `end`,而 `before_index: None`
时 `end == total`,`index >= end` 这个早退条件**永不触发** —— 于是客户端每次打开、
重试、刷新都重新读取并解析整个 transcript。

实测(localhost,`scripts/bench/thread-history-latency.sh`):同一请求只去掉
`user_query_limit` 是 0.0046s,带上是 1.06s,约 230 倍,且 warm 不变快。

## 改动

`ThreadCache::user_query_page`:当**缓存的物理尾部可证明包含整个窗口**时直接服务,
跳过流式扫描。命中条件只有两个,没有第三种:

```
target     = max(user_query_limit, 1)
tail_start = total_records - tail.len()

逆序遍历 tail:
1. 在 tail 内找到第 target 个 user query      -> 命中
2. 不足 target,但 tail.len() == total_records -> 命中(整个文件都在 tail 里)
3. 不足 target,且未覆盖全文件                 -> 必须 miss
```

第 3 种情况**不允许**用 tail 的记录数、字节数或 query 密度去推断。仓库里
`ThreadCache::cold_open_window` 用的是同一套证明,本实现与它同构。

`start` 的三个分支与流式路径逐条一致(`end == total`):无 query →
`total - fallback.max(1)`;不足 target(仅在覆盖全文件时可达)→ `0`;
找满 → 这 N 个里最旧的那个物理下标。

**全部是物理记录下标,不做任何 seq 运算。**

`before_index: Some(_)`(向上翻页)完全走原路径,未改动。

## 为什么不用 seq

`index == seq - 1` **不成立**。导入校验只要求 seq 严格递增,不要求从 1 起、不要求
无空洞;已提交测试固化了偏移起点(`records[0].seq == 41`、`repaired[0].seq == 7`)。

### 连带发现:既有缺陷(本轮不修,已在代码中标注)

`page_messages_by_index` 自己就在做 `start_seq = start + 1`。对偏移 transcript 这会
取错切片 —— **后果不是轻微偏移,而是首屏空白**:新增的 oracle 测试在旧路径上
返回 0 条消息(应为 15 条)。

本轮新路径不经过它,因此**顺带修好了最新窗口这一种情况**;向上翻页仍走旧映射,
仍然是错的。这是对已错误分支的部分正确化,没有破坏任何正确契约,但**不是完整的
imported-transcript 分页修复**。完整修复需要单独一轮,范围:`page_before_index`、
`page_after_index`、`before_index: Some` 的用户轮次分页、cache 与 disk 两种物理切片、
偏移/空洞、以及"首屏 → 向上翻页"集成测试。不要把真正按 seq 定义的
`records_after_seq` 一并改成 index 语义。

## 结果

同一台机器、同一批线程,改动前后(中位数 / 3 次):

| 文件 | window 前 | window 后 | no-uql(对照) |
|---|---|---|---|
| 373 MB / 55611 行 | 1.0933s | **0.0044s** | 0.0034s |
| 181 MB / 34599 行 | 0.7448s | **0.0147s** | 0.0041s |
| 115 MB / 16236 行 | 0.3640s | **0.0070s** | 0.0052s |

`window` 现在与不带 `user_query_limit` 的对照基本持平,惩罚消失。

### 效果的准确边界(条件式,不是无条件结论)

- **warm + tail 命中**:零 transcript 数据读取。上表即此情形。
- **warm + tail miss**:仍走流式扫描,最坏仍是全文件。
- **cold**:先完整 build cache;若新 tail 命中,合计一次全扫(原为两次);
  若 miss,还要再扫,最坏不止一次。

`message_count` → `with_built_cache` → `build_cache_streaming` 那次冷启动全扫**没有
消除**。目前没有更便宜且精确的 `total` 来源:thread-record 的 `history.message_count`
可能落后(transcript append 成功后 thread-record patch 允许失败且不回滚),
last seq 因偏移/空洞不等于 total,文件长度推不出记录数。

## 明确不做

- 不建持久化索引。
- 不调 cache 预算。
- 不改客户端(服务端靠 `user_query_limit` 判断游标过旧返回 `reset`)。
- 不修 `page_messages_by_index` 的 seq 映射(独立缺陷,已在代码中以 KNOWN DEFECT 标注)。
- **本轮未实现反向磁盘扫描**。方案 v2 设计过一个两阶段反向扫描器来处理 tail miss;
  实测表明缓存尾部已覆盖热路径,所以按最小正确面收敛,没有引入那份复杂度
  (线性反向行读取器 + 两阶段同 fd 物化)。tail miss 仍走既有流式扫描,正确但慢。

## 验证

- `cargo test -p garyx-router --all-targets`:235 passed。
- 新增 7 例(`newest_user_query_window_*`),含物理记录 oracle、seq 从 41 起且带空洞的
  导入 transcript、tail 不足 target 时**必须 miss**、无 user query 的 fallback 分支、
  不足 target 但覆盖全文件、首次读取后追加、transcript 缺失。
- 反向探针:禁用快路径后 2 例 FAIL —— 其一是 forward-scan 计数断言,
  其二是偏移 transcript 的 oracle(旧路径返回 0 条)。
- 新增 `#[cfg(test)]` 计数器 `user_query_forward_scans`,断言的是"确实没有扫描",
  而不是墙钟时间。
- `scripts/bench/thread-history-latency.sh` 前后对照(上表)。
