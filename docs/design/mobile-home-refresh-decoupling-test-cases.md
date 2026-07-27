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
| A1 | staleGated within TTL skips | lastCompleted = now − 1 min, ttl 5 min, no in-flight | `.skip` | |
| A2 | staleGated past TTL sweeps | lastCompleted = now − 6 min | `.startSweep` | |
| A3 | staleGated with no history sweeps | lastCompleted = nil | `.startSweep` | |
| A4 | forced always sweeps when idle | lastCompleted = now − 1 s, forced | `.startSweep` | |
| A5 | any request during in-flight joins | in-flight = true, both intents | `.joinInFlight` for both | |
| A6 | TTL boundary is exclusive-stale | lastCompleted = now − exactly ttl | `.startSweep` (age ≥ ttl is stale) | |

## B. Request-set integration tests (GaryxMobileTests, mocked transport, headless)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| B1 | Home pull (All) issues list only | home on All filter → pull-to-refresh | exactly `/api/recent-threads?tasks=include…` issued; **zero** catalog-set paths | |
| B2 | Home pull (Chats) issues list only | filter = Chats → pull-to-refresh | exactly `/api/recent-threads?tasks=exclude…`; zero catalog-set paths | |
| B3 | Home pull (Favorites) issues snapshot only | filter = Favorites → pull-to-refresh | exactly `/api/thread-favorites/snapshot`; zero catalog-set paths | |
| B4 | Filter switch issues no catalog requests | All → Chats → Favorites → All | only feed/snapshot transports observed | |
| B5 | Connect refresh still sweeps | fresh gateway scope connect | catalog-set paths issued once (forced) | |
| B6 | Management pull is forced | agents surface pull-to-refresh with lastCompleted = now − 1 s | catalog-set issued again | |
| B7 | Post-mutation readback is forced | bot edit save flow | catalog-set issued after save | |
| B8 | Stale-gated caller within TTL is silent | connect sweep completes → trigger composer ensure-thread path within TTL | no new catalog-set requests | |
| B9 | Stale-gated caller past TTL sweeps | same, with injected clock advanced past TTL | catalog-set issued once | |
| B10 | In-flight coalescing | hold sweep responses open → trigger forced + stale-gated again | each catalog path hit exactly once; both callers complete when responses release | |
| B11 | Superseded sweep does not stamp freshness | start sweep, supersede via runtime-generation bump, then staleGated request | superseded sweep must not update lastCompleted; policy returns `.startSweep` | |
| B12 | Home avatar regression | restored catalog cache, then home pull-to-refresh | home rows still resolve agent avatars; no catalog requests issued | |

## C. Simulator end-to-end (iPhone 17 Pro Max, iOS 26.5, light mode)

| # | Case | Steps | Expectation | Execution Record |
|---|---|---|---|---|
| C1 | Real pull-to-refresh network trace | launch against local gateway, settle, pull home list; capture gateway access pattern for the gesture window | only the feed request hits the gateway; list updates; avatars render | |
| C2 | Management surface unaffected | open Agents surface, pull-to-refresh | catalog requests observed; surface updates normally | |

## D. Regression sweep (headless)

| # | Case | Expectation | Execution Record |
|---|---|---|---|
| D1 | Existing suites | `GaryxHomeThreadListRefreshCommitTests` and the full `GaryxMobileCoreTests` SwiftPM suite pass unmodified in intent (mechanical fixture updates allowed, behavioral assertions preserved) | |
