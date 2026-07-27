# iOS Home Feed Sync Ownership Review Debt

Status: deferred from `#TASK-2785`. These items were identified while the
Home-feed synchronization design was prepared, but they are outside the
approved refresh-ownership and phase-machine scope. They require independent
tasks and must not be used as blockers for this implementation.

| # | Deferred debt | Source / follow-up boundary |
|---|---|---|
| D1 | `HomeProjectionGateway.endTransaction` can return without decrementing `transactionDepth`, potentially freezing Home projection. | `HomeProjectionActor.swift`; confidence 0.5. Reproduce with a focused concurrency test before changing behavior. |
| D2 | A second `connectAndRefresh` can move an already-ready connection back to checking and rebuild the navigation-shell occurrence. | `GaryxMobileModel+Gateway.swift`, `GaryxHomeObservationStore.swift`. Connection-shell lifecycle work, not feed ownership. |
| D3 | The app writes but does not read the Recent widget snapshot. A local fallback also needs a durable pagination-anchor protocol. | `GaryxMobileModel+ThreadList.swift`, `GaryxMobileWidgetData.swift`. Requires a separate persistence design. |
| D4 | The route path without a container mutates `path` synchronously without calling `applyCanonicalRouteProjection`. | `GaryxProductionRouteStack.swift`. Route projection ownership is separate. |
| D5 | The root `.task` has no identity; when `canConnectGateway` is false it can give up permanently without an explanation. | `GaryxMobileViews.swift`. Root connection UX is separate. |
| D6 | `hasAttemptedLastOpenedThreadRestore` is consumed before the restore decision is known. | `GaryxMobileModel+ThreadPersistence.swift`. Restore policy is separate. |
| D7 | Home hosts can be evicted by the route LRU, so any task attached to the Home SwiftUI tree is not long-lived. | `GaryxRouteStackContainer.swift`. The current change removes feed ownership from that tree; auditing other Home tasks remains separate. |
| D8 | `.equatable()` on the Home host is ineffective because its root view is constructed only when mounted. | `GaryxProductionRouteStack.swift`. Rendering optimization only. |
| D9 | `shouldRefreshSidebarThreads` rebuilds the full presentation snapshot to read one Boolean. | `GaryxMobileSidebarViews.swift`. Performance cleanup only. |
| D10 | Pager-level and feed-level lane contracts still describe different concurrency capabilities. | `GaryxHomeThreadListPager.swift` versus `GaryxRecentThreadFeeds.swift`. This task adds the required feed-owned single-flight trailing edge; reconciling the lower-level public contracts remains separate. |
| D11 | While Favorites remains selected, the resident Chats feed does not receive periodic refreshes. | `GaryxMobileModel+HomeFeedSync.swift`. Returning to Chats now submits and settles an explicit refresh intent; continuous off-selection refresh policy remains separate. |
| D12 | Defensively harden the Favorites-selected planner against an artificial `.ready` connection paired with an empty gateway scope. That combination is unreachable through the production exit ordering today, but a synthetic caller could otherwise keep planning `.refreshNow` while `selectedHeadRequestIsInternallyQueued` is false. | `GaryxMobileModel+HomeFeedSync.swift`. The adversarial review established that `exitCurrentGatewayScope()` deactivates the owner before clearing Favorites and that production `.ready` implies a configured URL, so this is robustness work, not a current bug or blocker. |

## Findings added during implementation

No additional reachable adjacent production defect was established. D12 records
an unreachable-state hardening opportunity from adversarial review and remains
separate.

Two findings were resolved inside the approved type / phase boundary rather
than deferred:

- A retained stale `GaryxRecentHeadAttempt` could previously be re-wrapped by
  an external module into a public loading presentation. The raw presentation
  constructors and `GaryxRecentHeadDomain` are now module-internal, while
  presentation fields are `private(set)` and Favorites exposes only its
  domain-derived presentation.
- Draining a pending head request relabelled an existing specific immediate
  debt (identity replacement or raced local mutation) as generic interruption.
  `oweImmediate` now preserves the first specific stall provenance.

Full app-target validation also exposed a test-fixture isolation issue:
long-lived scope owners can outlive a test method, so invalidating that
method's `URLSession` before deactivating its owner lets a later cadence create
a task on an invalidated session. The fixture now owns and deactivates every
test model and routes per-session protocol handlers by an opaque token. This
is validation infrastructure required by the new lifecycle contract, not
deferred product debt.

Disposition: keep D1–D12 in independent follow-up work. Do not expand the
Home-feed ownership implementation to address them.
