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

## Findings added during implementation

No additional adjacent production defect was established. Full app-target
validation did expose a test-fixture isolation issue: long-lived scope owners
can outlive a test method, so invalidating that method's `URLSession` before
deactivating its owner lets a later cadence create a task on an invalidated
session. The fixture now owns and deactivates every test model and routes
per-session protocol handlers by an opaque token. This is validation
infrastructure required by the new lifecycle contract, not deferred product
debt.

Disposition: keep D1–D11 in independent follow-up work. Do not expand the
Home-feed ownership implementation to address them.
