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

## B. Request-set integration tests (GaryxMobileTests, mocked transport, headless)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| B1 | Home pull (All) issues list only | home on All filter → pull-to-refresh | exactly `/api/recent-threads?tasks=include…` issued; **zero** catalog-set paths | **PASS (2026-07-28)** — `GaryxCatalogRefreshIntegrationTests.testB1HomePullAllIssuesOnlySelectedRecentFeed`. |
| B2 | Home pull (Chats) issues list only | filter = Chats → pull-to-refresh | exactly `/api/recent-threads?tasks=exclude…`; zero catalog-set paths | **PASS (2026-07-28)** — `testB2HomePullChatsIssuesOnlySelectedRecentFeed`. |
| B3 | Home pull (Favorites) issues snapshot only | filter = Favorites → pull-to-refresh | exactly `/api/thread-favorites/snapshot`; zero catalog-set paths | **PASS (2026-07-28)** — `testB3HomePullFavoritesIssuesOnlySnapshot`; also asserts no immediate visible-cadence follow-up. |
| B4 | Filter switch issues no catalog requests | All → Chats → Favorites → All | only feed/snapshot transports observed | **PASS (2026-07-28)** — `testB4FilterSwitchesNeverIssueCatalogRequests`. |
| B5 | Connect refresh still sweeps | fresh gateway scope connect | catalog-set paths issued once (forced) | **PASS (2026-07-28)** — `testB5ConnectRefreshStillRunsForcedCatalogSweep`; all 12 paths once. |
| B6 | Management pull is forced | agents surface pull-to-refresh with lastCompleted = now − 1 s | catalog-set issued again | **PASS (2026-07-28)** — `testB6ManagementPullRemainsForcedWithinTTL`; injected clock. |
| B7 | Post-mutation readback is forced | bot edit save flow | catalog-set issued after save | **PASS (2026-07-28)** — `testB7BotEditReadbackRemainsForcedWithinTTL`; real save orchestration path. |
| B8 | Stale-gated caller within TTL is silent | connect sweep completes → trigger composer ensure-thread path within TTL | no new catalog-set requests | **PASS (2026-07-28)** — `testB8ComposerEnsureThreadIsSilentWithinTTL`; real ensure-thread path. |
| B9 | Stale-gated caller past TTL sweeps | same, with injected clock advanced past TTL | catalog-set issued once | **PASS (2026-07-28)** — `testB9ComposerEnsureThreadSweepsPastTTL`; clock advanced without sleep. |
| B10 | In-flight coalescing | hold sweep responses open → trigger forced + stale-gated again | each catalog path hit exactly once; both callers complete when responses release | **PASS (2026-07-28)** — `testB10ConcurrentIntentsCoalesceOntoOneSweep`; deterministic transport gate, each path exactly once and both joiners awaited settlement. |
| B11 | Superseded sweep does not stamp freshness | start sweep, supersede via runtime-generation bump, then staleGated request | superseded sweep must not update lastCompleted; policy returns `.startSweep` | **PASS (2026-07-28)** — `testB11SupersededSweepDoesNotStampFreshness`; old flight released after generation bump, timestamp stayed nil, next stale-gated sweep ran. |
| B12 | Home avatar regression | restored catalog cache, then home pull-to-refresh | home rows still resolve agent avatars; no catalog requests issued | **PASS (2026-07-28)** — `testB12RestoredCatalogKeepsHomeAvatarWithoutPullSweep`; restored data-URL avatar resolved and pull issued zero catalog paths. |

B1–B12 were also executed together after the final single-flight audit:
12/12 passed in `/tmp/task-2798-b1-b12-final2.xcresult` on iPhone 17 Pro Max /
iOS 26.5. The final pre-start supersede guard was then rechecked against B10
and B11: 2/2 passed in `/tmp/task-2798-b10-b11-final.xcresult`.

## C. Simulator end-to-end (iPhone 17 Pro Max, iOS 26.5, light mode)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| C1 | Real pull-to-refresh network trace | launch against local gateway, settle, pull home list; capture gateway access pattern for the gesture window | only the feed request hits the gateway; list updates; avatars render | **PASS (2026-07-28)** — real local gateway, iPhone 17 Pro Max / iOS 26.5 / light. Temporary UI harness passed in `/tmp/task-2798-c1-real-gateway.xcresult`; proxy trace `/tmp/task-2798-c1-trace.jsonl` contains 6 successful `/api/recent-threads` page requests, 52,631 response bytes, and no other path. Updated list and cached agent avatars are visible in `/tmp/task-2798-c1-home-after-pull.png`. |
| C2 | Management surface unaffected | open Agents surface, pull-to-refresh | catalog requests observed; surface updates normally | **PASS (2026-07-28)** — same target/configuration. `/tmp/task-2798-c2-real-gateway.xcresult` passed; `/tmp/task-2798-c2-trace.jsonl` contains all 12 catalog paths with 200 responses (plus the Agents surface's subsequent provider-model requests), 664,937 response bytes total. Normal rendered surface: `/tmp/task-2798-c2-agents-after-pull.png`. |

## D. Regression sweep (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | Existing suites | `GaryxHomeThreadListRefreshCommitTests` and the full `GaryxMobileCoreTests` SwiftPM suite pass unmodified in intent (mechanical fixture updates allowed, behavioral assertions preserved) | **PASS (2026-07-28)** — existing Home refresh regression selection: 63/63 in `/tmp/task-2798-home-refresh-regression.xcresult`; full SwiftPM suite: 1,642/1,642 in `/tmp/task-2798-core-full.log`. |

## Implementation record

Final call-site scan: the former Home pull sweep was removed; all 23 remaining
calls are explicit (`forced`: 19, `staleGated`: 4), with no no-argument
fallback. The four stale-gated incidental paths are bot-list reconstruction,
composer ensure-thread, Bot Settings initial load, and workspace-sidebar
initial load. No adjacent pre-existing defect was changed or added to the
debt ledger during this implementation.
