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
| R1 | Parked pending freezes filter-switch intent | park a stale `pendingHeadRequest` on the nonTask feed (settle-re-arm path or test seam), phase not owing immediate; switch filter to Chats (`submitUserIntent(.userAction)`); drive the wake loop | no head request dispatched for `.nonTask`; no cadence timer scheduled; `pendingUserIntent` still parked | head request dispatches immediately (merged with the parked request); intent consumed | |
| R2 | Visibility flip recovers the parked intent (owner's workaround, pre-fix) | same setup as R1 frozen state, then `updateHomeVisibility(false)` → `updateHomeVisibility(true)` | the parked intent now dispatches — proving the reported "enter a bot thread and come back" recovery is this exact mechanism | with the fix, R1 already dispatched immediately; the flip is a no-op (no duplicate head request) | |
| R3 | Cadence survives the formerly-freezing state | R1 setup, no user intent at all | no timer scheduled after break (cadence dead) | evaluation exits only via planner `.sleep`/`.none` with a scheduled timer whenever demand or cadence remains | |

## P. Passthrough & state-machine invariants (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| P1 | Intent during in-flight head request | intent is not lost: it dispatches on the transport-finish wake (existing `transportDidFinish` → wake), not frozen | |
| P2 | Intent merges with parked pending | exactly one merged head request dispatches (no duplicate concurrent heads for one feed) | |
| P3 | Favorites intent passthrough | switching to Favorites while the snapshot provider is mid-refresh still triggers snapshot refresh convergence; no freeze | |
| P4 | Every evaluation exit is wake-covered | unit-level: for each reachable exit of the evaluation loop with pending demand, either a timer is scheduled or the blocking state's completion edge provably wakes (transport finish, settle effects, visibility, connection) — encoded as tests over the loop's observable outputs | |
| P5 | Pager-loading strand removed | head settle while pager `isLoadingMore` re-arms pending; load-more completion drains it without any external wake | |

## C. Cold-start orchestration (headless, mocked transport)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| C1 | List is first and unblocked | fresh connect: probe succeeds → observe request order | selected-feed `recent-threads` (or favorites snapshot) request is issued before any catalog-set/agent-targets/usage request completes-gates it; list commit does not await any of them | |
| C2 | Background work still happens | same run | agent targets, one forced catalog sweep, usage widget, and thread restore all execute in the background with connect requestId/generation guards intact | |
| C3 | Probe failure UX unchanged | unreachable gateway | fast fail into chooser exactly as today; no background work leaks | |
| C4 | Supersede safety | second connect (scope switch) while background work of the first is in flight | first connect's background results are discarded by generation guards; no cross-scope state bleed | |
| C5 | Pending deep link | connect with a pending thread route | route opens; home feed refresh still not blocked behind catalog sweep | |
| C6 | Background failure isolation | catalog sweep fails (transport error) on cold start | connect stays `.ready`; list is fresh; catalog surfaces show their own error/stale state; no connect failure surfaced | |

## S. Simulator end-to-end (iPhone 17 Pro Max, iOS 26.5, light mode)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| S1 | Cold start network trace | kill app, relaunch against local gateway, capture proxy trace of first 10 s | first data request after `/api/status` + chat-health is the selected feed; catalog sweep runs concurrently/after without delaying the first list commit | |
| S2 | Filter-switch stress | on device: switch All→Chats→Favorites→All repeatedly (≥20 cycles), including immediately after pull-to-refresh and immediately after returning from a thread | every switch converges to the correct feed without entering a thread; screen-capture evidence for at least one formerly-freezing sequence | |

## D. Regression (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | #TASK-2798 suite intact | B1–B13 + coalesced-intent regression + policy tests all pass unmodified in intent | |
| D2 | Full suites | `GaryxMobileTests` home suites + full SwiftPM `GaryxMobileCoreTests` green | |
