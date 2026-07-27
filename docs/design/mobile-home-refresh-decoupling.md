# Mobile Home Refresh / Catalog Sweep Decoupling

Status: approved for implementation (owner decision 2026-07-27)
Companion test cases: `docs/design/mobile-home-refresh-decoupling-test-cases.md`
Deferred adjacent debt: `docs/design/mobile-home-payload-review-debt.md`

## Problem (measured)

A single home-list pull-to-refresh on iOS transfers ~1.14 MB, of which the
thread list itself is only 5.4%:

| Request | Bytes | Role |
|---|---|---|
| `/api/recent-threads?tasks=include&limit=50` | 61,784 | the list the user asked for |
| `/api/custom-agents` | 748,384 | catalog sweep (97.8% inline avatar base64) |
| `/api/capsules` | 138,359 | catalog sweep |
| `/api/bot-consoles` | 82,055 | catalog sweep |
| `/api/channel-endpoints` | 50,762 | catalog sweep |
| `/api/channels/plugins` | 30,286 | catalog sweep |
| `/api/skills` + 6 more | ~28,000 | catalog sweep |
| **Total** | **1,140,743** | |

Cause: the home pull-to-refresh handler
(`App/GaryxMobile/GaryxMobileViews.swift`, `onRefreshAll`) fires
`Task { await model.refreshRemoteState() }` alongside the feed refresh.
`refreshRemoteState()` (`GaryxMobileModel+Gateway.swift`) launches 12
concurrent catalog requests. There is no TTL, no in-flight dedup, and 24 call
sites across the app trigger the full sweep unconditionally. Each completed
sweep also re-encodes a ~1 MB `GaryxMobileCatalogCacheSnapshot` JSON on the
`@MainActor` and writes it to `UserDefaults`
(`GaryxMobileModel+CatalogCache.swift`, `persistCatalogCacheSnapshot`).

Gateway-side query cost is not the problem (1–6 ms per endpoint measured
locally); the waste is transfer volume, redundant decode, and main-thread
cache re-encoding.

## Goal behavior

1. **Home pull-to-refresh refreshes exactly the selected feed** — the
   `recent-threads` page for All/Chats, the thread-favorites snapshot for
   Favorites — and issues **zero** catalog requests.
2. `refreshRemoteState` gets explicit staleness semantics instead of
   "every caller sweeps everything":
   - **forced sweep** — user is explicitly acting on catalog data
     (management-surface pull-to-refresh, post-mutation readback). Runs
     immediately, always.
   - **stale-gated sweep** — incidental callers that only need catalog data
     to be "reasonably fresh". Runs only if the last successful sweep is
     older than the TTL.
   - **in-flight coalescing** — while a sweep is running, both forced and
     stale-gated callers await the running sweep instead of issuing a second
     concurrent 12-request burst. (A forced request that arrives while a
     sweep is in flight awaits that sweep; it does not queue a second one.
     This keeps the semantics simple and is acceptable because the running
     sweep's responses are at most seconds old.)
3. Catalog TTL: **5 minutes** (`GaryxCatalogRefreshPolicy.defaultTTL`).
   Catalog surfaces are low-frequency data (agents, skills, bots, plugins);
   external mutations (e.g. desktop edits) are picked up by the next forced
   trigger, TTL expiry, or reconnect.

## Call-site classification

The decision rule: **a sweep is forced only when the user is looking at or
just mutated catalog data; everything else is stale-gated. The home feed
never sweeps.**

| Call site | Scenario | New behavior |
|---|---|---|
| `GaryxMobileViews.swift` `onRefreshAll` (home pull) | user refreshes thread list | **remove sweep entirely** |
| `GaryxMobileModel+Gateway.swift` connect refresh (~line 594) | gateway connect / scope switch | forced (this is the canonical cold-start refresh) |
| Management-surface `onRefresh` closures: `GaryxMobileSkillsViews.swift`, `GaryxMobileCommandsViews.swift`, `GaryxMobileAgentsViews.swift`, `GaryxMobileMcpViews.swift`, `GaryxMobileBotSettingsViews.swift`, `GaryxMobileSidebarViews.swift` (drawer/management refresh), `GaryxThreadListDrilldownViews.swift` | user pull-to-refresh on a catalog surface | forced |
| `GaryxMobileModel+Bots.swift` (8 sites), `GaryxMobileModel+AgentsWorkspaces.swift` (~line 901), `GaryxMobileModel+Automations.swift` (2 sites) | post-mutation readback after create/edit/delete | forced |
| `GaryxMobileModel+ThreadList.swift` (~line 304, bot thread-list reconstruction) | needs bot groups incidentally | stale-gated |
| `GaryxMobileModel+Composer.swift` (~line 1114, ensure-thread flow) | needs catalog incidentally | stale-gated |

Implementer note: the table lists the sites known at design time; classify any
site not listed here by the decision rule above, and record the final
classification in the implementation notes. Do not leave any call site on an
unconditional sweep path.

## Architecture

Follow the repo rule: pure decision logic in `GaryxMobileCore` with SwiftPM
tests; the app target keeps only orchestration.

- **`GaryxCatalogRefreshPolicy` (new, GaryxMobileCore)** — pure, testable:
  given (now, lastSuccessfulSweepCompletedAt, ttl, isSweepInFlight) and the
  request kind (forced / staleGated), returns the action
  (startSweep / joinInFlight / skip). All TTL and coalescing decisions live
  here; no timestamps are read inside view code.
- **App layer** — `refreshRemoteState(_ intent:)` becomes the single sweep
  entrypoint carrying the intent (`.forced` / `.staleGated`). It consults the
  policy, tracks `lastSuccessfulSweepCompletedAt` (updated only on a sweep
  that completed without being superseded), and holds the shared in-flight
  `Task` that joiners await. The existing `requestId` / `runtimeGeneration`
  supersede logic is unchanged.
- **Home feed path** — `requestHomeFeedRefresh` and the favorites snapshot
  path are already independent transports; the change removes the sweep call
  from `onRefreshAll`, nothing else about feed refresh changes.

### Home avatar regression guard

Home thread rows render agent avatars from the agents catalog. After this
change the home screen relies on (a) the restored
`GaryxMobileCatalogCacheSnapshot` at cold start and (b) the forced connect
refresh. Both already exist; the test cases pin that home rows still resolve
avatars without any sweep on pull-to-refresh.

## Impact

- Home pull-to-refresh: **1.14 MB → ~62 KB** (list only), and no ~1 MB
  main-thread catalog cache re-encode on the pull path.
- Catalog staleness on passive paths increases to at most 5 minutes; catalog
  surfaces the user actually looks at keep immediate refresh.
- No gateway API contract changes. No desktop changes.

## Explicitly out of scope (recorded debt, do not implement here)

See `docs/design/mobile-home-payload-review-debt.md`:
avatar extraction out of `/api/custom-agents` JSON, and
`recent_threads` row `thread_runtime` slimming. Gateway response compression
ships separately (gateway-side change, same decision).
