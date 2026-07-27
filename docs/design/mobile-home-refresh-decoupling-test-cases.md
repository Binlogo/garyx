# Test Cases: Mobile Home Refresh / Catalog Sweep Decoupling

Design: `docs/design/mobile-home-refresh-decoupling.md`

Execution rule (owner 2026-07-27): every case below must be actually executed
after implementation; record PASS/FAIL plus evidence (test name / log
excerpt) in the Execution Record column of each case before requesting
review. Headless tests are the default; the two simulator cases are the only
UI-level checks.

Test harness notes: request-set assertions use the existing mocked-transport
pattern from `Tests/GaryxMobileTests/GaryxHomeThreadListRefreshCommitTests.swift`
(URL-matched handlers; assert on the set of request paths issued). Policy
cases are pure SwiftPM tests in `Tests/GaryxMobileCoreTests`. Time is injected
— no sleeps, no wall-clock dependence.

Catalog request set = the 12 sweep paths: `/api/custom-agents`, `/api/skills`,
`/api/settings`, `/api/automations`, `/api/commands/shortcuts`,
`/api/mcp-servers`, `/api/channel-endpoints`, `/api/workspaces`,
`/api/configured-bots`, `/api/bot-consoles`, `/api/channels/plugins`,
`/api/capsules`.

## A. Policy unit tests (GaryxMobileCore, pure)

| # | Case | Setup | Expectation | Execution Record |
|---|---|---|---|---|
| A1 | staleGated within TTL skips | lastCompleted = now − 1 min, ttl 5 min, no in-flight | `.skip` | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testStaleGatedWithinTTLskips`; pure injected `Date`, no sleep. |
| A2 | staleGated past TTL sweeps | lastCompleted = now − 6 min | `.startSweep` | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testStaleGatedPastTTLsweeps`. |
| A3 | staleGated with no history sweeps | lastCompleted = nil | `.startSweep` | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testStaleGatedWithNoHistorySweeps`. |
| A4 | forced always sweeps when idle | lastCompleted = now − 1 s, forced | `.startSweep` | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testForcedAlwaysSweepsWhenIdle`. |
| A5 | any request during in-flight joins | in-flight = true, both intents | `.joinInFlight` for both | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testAnyRequestDuringInFlightJoins`; both intents asserted. |
| A6 | TTL boundary is exclusive-stale | lastCompleted = now − exactly ttl | `.startSweep` (age ≥ ttl is stale) | **PASS (2026-07-28)** — `GaryxCatalogRefreshPolicyTests.testTTLBoundaryIsExclusiveStale`. |

Final focused execution: 6/6 passed in
`/tmp/task-2798-final-policy.log`; all times are injected and no test
sleeps or reads the wall clock.

## B. Request-set integration tests (GaryxMobileTests, mocked transport, headless)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| B1 | Home pull (All) issues list only | home on All filter → pull-to-refresh | exactly `/api/recent-threads?tasks=include…` issued; **zero** catalog-set paths | **PASS (2026-07-28)** — `GaryxCatalogRefreshIntegrationTests.testB1HomePullAllIssuesOnlySelectedRecentFeed`. |
| B2 | Home pull (Chats) issues list only | filter = Chats → pull-to-refresh | exactly `/api/recent-threads?tasks=exclude…`; zero catalog-set paths | **PASS (2026-07-28)** — `testB2HomePullChatsIssuesOnlySelectedRecentFeed`. |
| B3 | Home pull (Favorites) issues snapshot only | filter = Favorites → pull-to-refresh | exactly `/api/thread-favorites/snapshot`; zero catalog-set paths | **PASS (2026-07-28)** — `testB3HomePullFavoritesIssuesOnlySnapshot`; also asserts no immediate visible-cadence follow-up. |
| B4 | Filter switch issues no catalog requests | All → Chats → Favorites → All | only feed/snapshot transports observed | **PASS (2026-07-28)** — `testB4FilterSwitchesNeverIssueCatalogRequests`. |
| B5 | Connect refresh still sweeps | fresh gateway scope connect | catalog-set paths issued once (forced) | **PASS (2026-07-28)** — `testB5ConnectRefreshStillRunsForcedCatalogSweep`; exact 12-path set asserted. Per-path once-ness is asserted by B10. |
| B6 | Management pull is forced | agents surface pull-to-refresh with lastCompleted = now − 1 s | catalog-set issued again | **PASS (2026-07-28)** — `testB6ManagementPullRemainsForcedWithinTTL`; injected clock. |
| B7 | Post-mutation readback is forced | bot edit save flow | catalog-set issued after save | **PASS (2026-07-28)** — `testB7BotEditReadbackRemainsForcedWithinTTL`; real save orchestration path. |
| B8 | Stale-gated caller within TTL is silent | connect sweep completes → trigger composer ensure-thread path within TTL | no new catalog-set requests | **PASS (2026-07-28)** — `testB8ComposerEnsureThreadIsSilentWithinTTL`; real ensure-thread path. |
| B9 | Stale-gated caller past TTL sweeps | same, with injected clock advanced past TTL | catalog-set issued once | **PASS (2026-07-28)** — `testB9ComposerEnsureThreadSweepsPastTTL`; clock advanced without sleep. |
| B10 | In-flight coalescing | hold sweep responses open → trigger forced + stale-gated again | each catalog path hit exactly once; both callers complete when responses release | **PASS (2026-07-28)** — `testB10ConcurrentIntentsCoalesceOntoOneSweep`; deterministic transport gate, each path exactly once and both joiners awaited settlement. |
| B11 | Superseded sweep does not stamp freshness | start sweep, supersede via runtime-generation bump, then staleGated request | superseded sweep must not update lastCompleted; policy returns `.startSweep` | **PASS (2026-07-28)** — `testB11SupersededSweepDoesNotStampFreshness`; old flight released after generation bump, timestamp stayed nil, next stale-gated sweep ran. |
| B12 | Home avatar regression | restored catalog cache, then home pull-to-refresh | home rows still resolve agent avatars; no catalog requests issued | **PASS (2026-07-28)** — `testB12RestoredCatalogKeepsHomeAvatarWithoutPullSweep`; restored data-URL avatar resolved and pull issued zero catalog paths. |
| B13 | Home pull retains canonical Home commit | seed a cached pinned thread that is absent from the returned page plus a selected Recent thread with cached runtime → pull All | only the selected Recent feed is requested; the page-external pinned row remains; runtime carry-over and selected title update still commit | **PASS (2026-07-28)** — `testB13HomePullCommitsSelectedFeedWithoutDroppingPinnedSection`; observed request paths are limited to `/api/recent-threads?tasks=include…`, with no `/api/thread-pins` or summary backfill. |

B1–B13 plus the coalesced-intent regression
`testConcurrentPullDoesNotNarrowQueuedUserAction` were executed together after
the final test-lifecycle fix: 14/14 passed as the first suite in the
post-commit 77/77 combined run
`/tmp/task-2798-final-combined.xcresult` on iPhone 17 Pro Max / iOS 26.5.
The coalesced-intent case proves a concurrent pull cannot narrow a queued
user action's favorites, refreshed-pins, or secondary-feed work.

## C. Simulator end-to-end (iPhone 17 Pro Max, iOS 26.5, light mode)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| C1 | Real pull-to-refresh network trace | launch against local gateway, settle, pull home list; capture gateway access pattern for the gesture window | only the feed request hits the gateway; list updates; avatars render | **PASS (2026-07-28)** — real local gateway, iPhone 17 Pro Max / iOS 26.5 / light. The tracked `Task2798CatalogRefreshE2ETests.testC1HomePullAgainstRealGateway` ran via ordinary `xcodebuild test` after a post-commit clean build; app and UI-test binaries were rebuilt at 02:15:17. `/tmp/task-2798-final-c1.xcresult` passed; proxy trace `/tmp/task-2798-c1-trace.jsonl` contains 6 successful `/api/recent-threads` page/range-fill requests, 52,471 response bytes, and no pins, summary, or catalog path. Updated list, preserved pinned section, and cached agent avatars are visible in `/tmp/task-2798-final-c1-home-after-pull.png`. |
| C2 | Management surface unaffected | open Agents surface, pull-to-refresh | catalog requests observed; surface updates normally | **PASS (2026-07-28)** — same target/configuration and tracked UI-test source. `/tmp/task-2798-final-c2.xcresult` passed on the post-commit bundle; `/tmp/task-2798-c2-trace.jsonl` contains all 12 catalog paths with 200 responses plus the Agents surface's 5 provider-model requests, all 200, for 665,144 response bytes total. Normal rendered surface: `/tmp/task-2798-final-c2-agents-after-pull.png`. |

## D. Regression sweep (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | Existing suites | `GaryxHomeThreadListRefreshCommitTests` and the full `GaryxMobileCoreTests` SwiftPM suite pass unmodified in intent (mechanical fixture updates allowed, behavioral assertions preserved) | **PASS (2026-07-28)** — post-commit B + Home combined selection: 77/77 (B 14/14, Home 63/63) in `/tmp/task-2798-final-combined.xcresult`; its post-B log contains no leaked `thread-home` / `thread-created` stream, invalidated-session exception, or process crash. Full SwiftPM suite: 1,643/1,643 in `/tmp/task-2798-reviewfix-core-full.log`. |

## Implementation record

Final call-site scan: the former Home pull sweep was removed; all 23 remaining
calls are explicit (`forced`: 19, `staleGated`: 4), with no no-argument
fallback. The four stale-gated incidental paths are bot-list reconstruction,
composer ensure-thread, Bot Settings initial load, and workspace-sidebar
initial load. Selected-feed pull tickets use the canonical Home projection
commit with cached pins, so row/runtime/title reconciliation still runs without
widening the approved feed-only request set. Merged pending intents retain the
strongest projection work, so a pull cannot narrow an already queued user
action. The real-gateway UI harness is tracked in the UI-test target, and the
mocked integration fixture drains each model's complete gateway runtime before
invalidating its sessions. The adjacent pre-existing unreachable-gateway test
timing flake observed during stress repetition is recorded as Debt 3 in
`docs/design/mobile-home-payload-review-debt.md` and was not changed here.
