# Mobile Cold-Start Critical Path & Home Feed Intent Passthrough

Status: approved direction (owner 2026-07-28); reproduction-first per bug rule
Companion test cases: `docs/design/mobile-cold-start-and-intent-test-cases.md`
Prior related work: `docs/design/mobile-home-refresh-decoupling.md` (#TASK-2798)

## Two confirmed defects, one module

### Defect 1 — filter switch intent can freeze (user-visible bug)

Symptom (owner report): switching All / Chats / Favorites in the home top bar
sometimes does not take effect; entering any bot thread from the drawer and
returning makes it apply.

Confirmed mechanism (code-verified, line refs at analysis time):

1. `selectRecentThreadFilter` → `requestHomeFeedRefresh(.userAction)` →
   `submitUserIntent` parks a `pendingUserIntent` on
   `GaryxHomeFeedSyncCoordinator` and calls `wake()`
   (`GaryxMobileModel+HomeFeedSync.swift`).
2. `evaluateUntilWaiting()` cancels the cadence timer at entry, then has a
   short-circuit **before the planner is consulted** (~line 270):
   when `selectedHeadRequestIsInternallyQueued` (the selected feed's
   internal `pendingHeadRequest != nil`) and the phase does not owe an
   immediate request, it `break`s — **no timer scheduled, planner never
   sees `hasPendingUserIntent`**. The user's intent is frozen and the
   coordinator stops self-scheduling entirely (the 10 s cadence died with
   the cancelled timer).
3. The feed's internal `pendingHeadRequest` is re-armed **unconditionally on
   every head settle** (`GaryxRecentThreadFeeds.swift` `settleHead`, ~line
   753) and only drained when `headPhase.activeAttempt == nil` and the pager
   is not loading more (`drainPendingHeadEffects`). The stale-pending window
   is therefore common, which is why the freeze is intermittent.
4. Recovery today is any external `wake()`. Returning from a thread commits
   the route → `applyCommittedCanonicalRouteProjection` →
   `updateHomeVisibility` → wake → re-evaluate → planner finally runs the
   parked intent. That is exactly the owner's "enter a bot thread and come
   back" workaround.

Note: `GaryxHomeFeedSyncPlanner.next` itself already prioritizes
`hasPendingUserIntent` above everything except background/connection gating.
The defect is purely that one evaluation path exits before consulting it.

### Defect 2 — cold start serializes the home list behind a 1.08 MB sweep

`connectAndRefresh()` (`GaryxMobileModel+Gateway.swift` ~546) is a serial
await chain: `status()` + `chatHealth()` probe (5 s timeout each) →
`restoreLastOpenedThreadIfNeeded()` → `await refreshAgentTargets()` →
`await refreshRemoteState(.forced)` (12 catalog endpoints, 1.08 MB) →
`await refreshCodingUsageWidget()` → pending-route handling. The home feed's
first network refresh is not on this chain at all — it is event-driven via
the coordinator — but the chain monopolizes `@MainActor` slices, bandwidth,
and the connection while it runs. Owner-set target behavior: **probe, then
refresh the visible list; everything else is background.**

## Goal behavior

1. **Cold-start critical path = probe + one list request.** After the
   reachability probe succeeds and `connectionState = .ready`, the selected
   home feed refresh is requested immediately. Nothing else is awaited before
   it.
2. **Everything else is background, concurrent, and non-blocking**: last-
   opened-thread restore, `refreshAgentTargets`, the forced catalog sweep
   (still one forced sweep per connect, still through
   `GaryxCatalogRefreshPolicy`), and the usage widget all run as structured
   background work gated by the existing requestId / runtimeGeneration
   supersede checks. Their failures surface exactly as today (per-domain
   error state), never as a connect failure, and none of them may delay the
   first feed paint.
   - Pending deep-link / pending-route handling keeps its current relative
     order guarantees with respect to thread restore, but moves off the
     list's critical path. If a pending route targets a thread, the route
     open may proceed concurrently with the home feed refresh.
3. **User intent passes through unconditionally.** Remove the
   internally-queued short-circuit. The evaluation loop always consults the
   planner; "selected feed has an internally queued head request" becomes
   planner/demand input or is resolved by merging: when a user intent
   arrives while a stale `pendingHeadRequest` is parked, the two merge (the
   feed's `merging(_:)` already exists) and dispatch immediately.
4. **Structural rule (no-dead-corner state machine):** every exit path of
   `evaluateUntilWaiting` must either schedule a timer or be provably
   wake-covered by an external event source. Encode this as a reviewed
   invariant comment plus tests; do not leave any bare `break` that strands
   pending demand.
5. **Re-arm hygiene:** `settleHead`'s unconditional pending re-arm must not
   be able to strand demand. Either the re-armed pending converts to an
   effect in the same settle (current fast path), or the state that blocks
   conversion (active attempt / pager loading) must re-drain on its own
   completion edge. Keep the range-fill chain semantics; eliminate only the
   stranded-window.

## Non-goals / preserved behavior

- No gateway API changes; no desktop changes.
- The forced connect sweep, TTL policy, in-flight coalescing, and all
  #TASK-2798 behavior (B1–B13) are preserved.
- Favorites keeps its snapshot-owned transport.
- The connect probe timeout/failure UX (fast fail into chooser) is unchanged.

## Reproduction-first (bug rule)

Defect 1 lands only after a deterministic reproduction exists and fails on
the pre-fix tree: park a stale `pendingHeadRequest` on the selected feed,
submit a filter-switch intent, assert (a) no head request dispatches and no
timer is scheduled (frozen), and (b) a subsequent `updateHomeVisibility`
flip dispatches it (matching the owner's workaround). The same two tests
must pass inverted after the fix (intent dispatches immediately; visibility
flip is irrelevant). These are R1/R2 in the test-case doc and they are the
review contract for the bug half.

## Impact

- Cold start to usable, fresh list: one RTT after probe instead of waiting
  behind agent targets + 1.08 MB sweep decode on the main actor.
- Filter switches become deterministic: the parked-intent freeze class is
  removed structurally, not patched around.
- Touched surfaces: `GaryxMobileModel+Gateway.swift` (connect orchestration),
  `GaryxMobileModel+HomeFeedSync.swift` (evaluation loop),
  `GaryxRecentThreadFeeds.swift` (pending re-arm hygiene), planner/demand
  types in `GaryxMobileCore` as needed — with SwiftPM tests for every pure
  piece.
