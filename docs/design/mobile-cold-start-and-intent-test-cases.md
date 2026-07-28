# Test Cases: Cold-Start Critical Path & Intent Passthrough

Design: `docs/design/mobile-cold-start-and-intent-passthrough.md`

Execution rule (owner): every case is actually executed; record PASS/FAIL +
evidence in the Execution Record column before requesting review. R1/R2 must
additionally record the **pre-fix failing run** (the reproduction) — that
pre-fix evidence is part of the review contract. Headless first; simulator
cases are the end-to-end tail. Time injected; no sleeps in unit tests.

Catalog request set = the 12 sweep paths (see
`mobile-home-refresh-decoupling-test-cases.md`).

## R. Reproduction (bug half — must fail pre-fix, pass post-fix)

| # | Case | Steps | Pre-fix expectation (reproduction) | Post-fix expectation | Execution Record |
|---|---|---|---|---|---|
| R1 | Parked pending freezes filter-switch intent | park a stale `pendingHeadRequest` on the nonTask feed (settle-re-arm path or test seam), phase not owing immediate; switch filter to Chats (`submitUserIntent(.userAction)`); drive the wake loop | no head request dispatched for `.nonTask`; no cadence timer scheduled; `pendingUserIntent` still parked | head request dispatches immediately (merged with the parked request); intent consumed | **PRE-FIX FAIL (2026-07-28)** — `testR1ParkedPendingDoesNotFreezeFilterSwitchIntent`: expected one Chats logical head, observed `0`; `pendingUserIntent(.userAction)` remained parked. `/tmp/task-2806-r-prefx-behavior-v2.xcresult`. **POST-FIX PASS (2026-07-28)** — one merged Chats head dispatched and the intent was consumed; R1–R3 3/3 passed on iPhone 17 Pro Max / iOS 26.5. `/tmp/task-2806-r-post-intent-v2.xcresult`. |
| R2 | Visibility flip recovers the parked intent (owner's workaround, pre-fix) | same setup as R1 frozen state, then `updateHomeVisibility(false)` → `updateHomeVisibility(true)` | the parked intent now dispatches — proving the reported "enter a bot thread and come back" recovery is this exact mechanism | with the fix, R1 already dispatched immediately; the flip is a no-op (no duplicate head request) | **PRE-FIX FAIL (2026-07-28)** — `testR2VisibilityFlipIsIrrelevantAfterImmediateIntentDispatch`: immediate pre-flip count was `0`; after the test seam modeled the transient queue owner consuming its request, the visibility pulse dispatched the parked user intent and the final count was `1` (only the pre-flip assertion failed). `/tmp/task-2806-r-prefx-behavior-v2.xcresult`. **POST-FIX PASS (2026-07-28)** — the head was already dispatched before the visibility pulse; owner release plus leaving/returning Home did not dispatch a duplicate. `/tmp/task-2806-r-post-intent-v2.xcresult`. |
| R3 | Cadence survives the formerly-freezing state | R1 setup, no user intent at all | no timer scheduled after break (cadence dead) | evaluation exits via planner `.sleep` with a timer or `.waitForExternalWake` with a named owner edge; cadence remains scheduled | **PRE-FIX FAIL (2026-07-28)** — `testR3CadenceSurvivesInternallyParkedHeadRequest`: expected one cadence head plus a re-armed timer; observed head count `0` and no timer. `/tmp/task-2806-r-prefx-behavior-v2.xcresult`. **POST-FIX PASS (2026-07-28)** — one cadence head dispatched and the injected-time coordinator re-armed its timer. `/tmp/task-2806-r-post-intent-v2.xcresult`. |

## P. Passthrough & state-machine invariants (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| P1 | Intent during in-flight head request | intent is not lost: it dispatches on the transport-finish wake (existing `transportDidFinish` → wake), not frozen | **PASS (2026-07-28)** — `testUserPullDuringActiveHeadLeavesOneTrailingReplacement` observed the user request parked behind the active transport, then one complete trailing replacement after transport finish. P1/P3 2/2 passed. `/tmp/task-2806-p1-p3.xcresult`. |
| P2 | Intent merges with parked pending | exactly one merged head request dispatches (no duplicate concurrent heads for one feed) | **PASS (2026-07-28)** — `testP2RunnableParkedRequestMergesIntoExactlyOneHeadEffect` asserted one effect carrying the strongest source, replacement flag, and projection commit, with no pending request left. Included in the 1,649/1,649 Core run. `/tmp/task-2806-d2-core-final.log`. |
| P3 | Favorites intent passthrough | switching to Favorites while the snapshot provider is mid-refresh still triggers snapshot refresh convergence; no freeze | **PASS (2026-07-28)** — `testP3FavoritesIntentConvergesWhenSnapshotIsAlreadyInFlight` reached `.ready`, exposed the expected ID, and consumed the intent after a post-intent snapshot. P1/P3 2/2 passed. `/tmp/task-2806-p1-p3.xcresult`. |
| P4 | Every evaluation exit is wake-covered | unit-level: for each reachable exit of the evaluation loop with pending demand, either a timer is scheduled or the blocking state's completion edge provably wakes (transport finish, settle effects, visibility, connection) — encoded as tests over the loop's observable outputs | **PASS (2026-07-28)** — `testP4EveryTimerlessWaitNamesItsExternalWakeOwner` covered visibility, connection, active-head completion, load-more completion, and new user intent; cadence/deadline exits are covered by the planner timer tests and R3. Included in the 1,649/1,649 Core run. `/tmp/task-2806-d2-core-final.log`. |
| P5 | Pager-loading strand removed | head settle while pager `isLoadingMore` re-arms pending; load-more completion drains it without any external wake | **PASS (2026-07-28)** — `testRefreshBlockedByLoadMoreTrailsImmediatelyAfterCompletion` observed `.waitingForLoadMore`, then a load-more completion emitted the owned trailing head and cleared the queue without another wake. Included in the 1,649/1,649 Core run. `/tmp/task-2806-d2-core-final.log`. |

## C. Cold-start orchestration (headless, mocked transport)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| C1 | List is first and unblocked | fresh connect: probe succeeds → observe request order | selected-feed `recent-threads` (or favorites snapshot) request is issued before any catalog-set/agent-targets/usage request completes-gates it; list commit does not await any of them | **PASS (2026-07-28)** — `testC1SelectedFeedCommitsWhileCatalogSweepIsBlocked` held the catalog transport open and proved the selected feed committed first. 1/1 passed. `/tmp/task-2806-c1-async-gate.xcresult`. |
| C2 | Background work still happens | same run | agent targets, one forced catalog sweep, usage widget, and thread restore all execute in the background with connect requestId/generation guards intact | **PASS (2026-07-28)** — `testC2EveryConnectBackgroundDomainExecutes` observed route restore, agent targets, usage, and exactly one policy-mediated forced catalog sweep. C2–C6 5/5 passed. `/tmp/task-2806-c2-c6-first.xcresult`. |
| C3 | Probe failure UX unchanged | unreachable gateway | fast fail into chooser exactly as today; no background work leaks | **PASS (2026-07-28)** — `testC3ProbeFailureStartsNoBackgroundWork` reached chooser/down state without starting any background domain. `/tmp/task-2806-c2-c6-first.xcresult`. |
| C4 | Supersede safety | second connect (scope switch) while background work of the first is in flight | first connect's background results are discarded by generation guards; no cross-scope state bleed | **PASS (2026-07-28)** — `testC4SecondConnectDiscardsFirstScopeBackgroundResults` superseded a gated first connect and retained only the second scope's result. `/tmp/task-2806-c2-c6-first.xcresult`. |
| C5 | Pending deep link | connect with a pending thread route | route opens; home feed refresh still not blocked behind catalog sweep | **PASS (2026-07-28)** — `testC5PendingThreadRouteRunsBesideUnblockedHomeFeed` opened the route while the feed committed independently of the blocked catalog work. `/tmp/task-2806-c2-c6-first.xcresult`. |
| C6 | Background failure isolation | catalog sweep fails (transport error) on cold start | connect stays `.ready`; list is fresh; catalog surfaces show their own error/stale state; no connect failure surfaced | **PASS (2026-07-28)** — `testC6CatalogFailureDoesNotFailConnectOrSelectedFeed` kept the connection ready and feed fresh while preserving the catalog domain's own failure. `/tmp/task-2806-c2-c6-first.xcresult`. |

## S. Simulator end-to-end (iPhone 17 Pro Max, iOS 26.5, light mode)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| S1 | Cold start network trace | kill app, relaunch against local gateway, capture proxy trace of first 10 s | first data request after `/api/status` + chat-health is the selected feed; catalog sweep runs concurrently/after without delaying the first list commit | **PASS (2026-07-28)** — light-mode iPhone 17 Pro Max / iOS 26.5 UI run: after the probes, request 5 was selected-Home work; selected `recent-threads` request 7 started before first background request 8 and returned 200; all 12 catalog paths plus agent targets and usage ran, with catalog responses finishing after the feed. 1/1 passed. Result: `/tmp/task-2806-s1-first.xcresult`; trace/screenshot: `/tmp/task-2806-s1-first-attachments/`. |
| S2 | Filter-switch stress | on device: switch All→Chats→Favorites→All repeatedly (≥20 cycles), including immediately after pull-to-refresh and immediately after returning from a thread | every switch converges to the correct feed without entering a thread; screen-capture evidence for at least one formerly-freezing sequence | **PASS (2026-07-28)** — light-mode iPhone 17 Pro Max / iOS 26.5 completed 20/20 All→Chats→Favorites→All cycles; the first cycle followed pull-to-refresh and the second followed a thread return. Every selection awaited a new successful matching request; captured totals (including range-fill) were All 138, Chats 46, Favorites 81. 1/1 passed. Result: `/tmp/task-2806-s2-second.xcresult`; trace/screenshot: `/tmp/task-2806-s2-second-attachments/`. |

## D. Regression (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | #TASK-2798 suite intact | B1–B13 + coalesced-intent regression + policy tests all pass unmodified in intent | **PASS (2026-07-28)** — B1–B13 plus `testConcurrentPullDoesNotNarrowQueuedUserAction`: 14/14; catalog policy tests: 6/6. `/tmp/task-2806-d1-b.xcresult`, `/tmp/task-2806-d1-policy-final.log`. |
| D2 | Full suites | `GaryxMobileTests` home suites + full SwiftPM `GaryxMobileCoreTests` green | **PASS (2026-07-28)** — final-tree Home test combination 87/87 on iPhone 17 Pro Max / iOS 26.5; final-tree full SwiftPM Core suite 1,649/1,649. `/tmp/task-2806-d2-home-final-v2.xcresult`, `/tmp/task-2806-d2-core-final.log`. |
