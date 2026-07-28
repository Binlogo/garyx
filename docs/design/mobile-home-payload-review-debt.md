# Mobile Home Payload — Recorded Debt (deferred by owner, 2026-07-27)

Origin: home-list slowness investigation (this file records the two items the
owner deferred; items 1 and 3 of that investigation shipped separately — see
`docs/design/mobile-home-refresh-decoupling.md` and the gateway response
compression change).

## Debt 1: Agent avatars inlined in `/api/custom-agents` JSON

- Measured: 748,384 B response; 97.8% (720,120 B) is `avatar_data_url`
  base64. Six custom agents carry 85–108 KB uncompressed PNGs (built-ins are
  2–3 KB). base64 adds a further 33% over raw bytes, and data-URLs get no
  HTTP-level caching, so every catalog fetch re-downloads every avatar.
- The same base64 blobs are re-encoded into the
  `GaryxMobileCatalogCacheSnapshot` JSON written to `UserDefaults` on the
  `@MainActor` (`persistCatalogCacheSnapshot`, 23 call sites), making each
  persist a ~1 MB main-thread encode into a plist-backed store.
- Direction when picked up: serve avatars from a dedicated endpoint
  (`/api/custom-agents/{id}/avatar`) with `ETag`/`Cache-Control`; catalog
  rows carry a stable avatar reference (URL + content hash), clients cache
  images outside the JSON snapshot; recompress oversized source PNGs.
  Touches gateway API + desktop + mobile + catalog cache schema — needs its
  own design doc.

## Debt 2: `recent_threads` row `thread_runtime` bloat

- Measured: 886 B/row at limit=50; `thread_runtime` is 360 B/row (40.7%),
  carrying `sdk_session_id`, `model_service_tier`, and duplicated
  `model`/`model_override`, `model_reasoning_effort`/
  `model_reasoning_effort_override` pairs that list rendering never reads.
  Dropping it shrinks the list payload ~29%.
- Direction when picked up: audit desktop + mobile consumers of
  `GaryxRecentThreadsPage` for actual field usage, then either remove
  `thread_runtime` from list rows (detail routes already carry it) or reduce
  it to the fields lists render. Cross-client API contract change — needs
  consumer audit first.

## Debt 3: Unreachable-gateway Home reducer test timing flake

- `GaryxHomeThreadListRefreshCommitTests.
  testUnreachableGatewayPresentsSetupInsteadOfHomeSkeleton` intermittently
  observes `.empty` instead of the reducer's retained
  `.loadingSkeleton(rowCount: 6)` debt after the connection failure wins the
  race. It reproduces with the Home suite alone and in unrelated control
  combinations; it predates the catalog-refresh work.
- Direction when picked up: replace the live connection-failure timing with a
  deterministic transport gate and explicitly settle the reducer transition
  before asserting both the hidden Home debt and the visible setup root.

## Debt 4: Favorites user action can schedule a redundant third snapshot

- `makeHomeFeedRefreshEffects` starts the general asynchronous
  capability-aware Favorites refresh and, when Favorites is selected, also
  calls the provider's synchronous `requestRefresh`. If the asynchronous
  request crosses the first flight's settlement boundary, it can mark the
  already-started trailing flight dirty and produce a third snapshot. The
  provider still converges with no pending intent or active attempt; this
  predates #TASK-2806 and is outside its freeze/cold-start contract.
- Evidence: the required full Home regression run for #TASK-2806 observed
  three successful snapshot transports in
  `testP3FavoritesIntentConvergesWhenSnapshotIsAlreadyInFlight`, while the
  focused run observed two. The P3 contract asserts post-intent convergence,
  not an exact transport count.
- Direction when picked up: make Favorites selection own one capability-aware
  refresh entry point so the general and selected-filter paths cannot both
  dirty the same generation. Preserve capability upgrade replacement and the
  provider's trailing-dirty fence.

## Debt 5: Feed convergence waiters do not inspect reducer-owned pending work

- `GaryxHomeFeedSyncCoordinator.settleWaitersIfConverged` checks the active
  head phase and coordinator-owned effects, but `hasQueuedRequest` does not
  include a `GaryxRecentThreadFeedState.pendingHeadRequest` parked behind
  load-more. The load-more completion still drains that request and the feed
  converges, but an awaiting caller can be released before the trailing head
  finishes.
- This waiter bookkeeping predates #TASK-2806 and is separate from its
  no-strand contract: P5 proves the reducer-owned request drains on the
  load-more completion edge without another wake.
- Direction when picked up: include reducer-owned queued state in the
  convergence proof and add a deterministic gated-load-more test that pins
  both waiter lifetime and trailing transport completion.

These items are adjacent findings, not regressions; per the scope rule they
must not ride along inside other tasks' review loops.
