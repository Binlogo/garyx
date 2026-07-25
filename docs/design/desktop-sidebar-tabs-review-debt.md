# Desktop Sidebar Tabs — Review Debt

Adjacent issues found while implementing `docs/design/desktop-sidebar-tabs.md`
(#TASK-2705). Per the scope rule, none of these were folded into that change:
the requirement's own surface takes no compromises, but neighbouring
pre-existing problems get recorded here and picked up as their own work.

## 1. Recent-filter selection is persisted on iOS, dropped on Mac

- iOS: persisted to UserDefaults —
  `mobile/garyx-mobile/Sources/GaryxMobileCore/GaryxRecentThreadFilterStorage.swift`,
  read in `GaryxMobileModel.swift`.
- Mac: reset to `"all"` on every launch and every gateway switch —
  `desktop/garyx-desktop/src/renderer/src/app-shell/recent-thread-feeds.ts`
  (initial state) and its scope-reset path.

Effect: switching the L2 rail to Chats is remembered on iPhone, forgotten on
Mac. A real cross-platform divergence, but out of scope for the sidebar tabs.

Note this is now *less* visible than before: the sidebar's Threads tab is
permanently the Chats list, so the rail's filter matters less than it used to.
Decide whether to persist it or to declare the rail's filter intentionally
transient before doing any work here.

## 2. Recent-filter order differs between platforms

- iOS: `[all, nonTask, favorites]` — `GaryxRecentThreadFeeds.swift`.
- Mac: `["nonTask", "all", "favorites"]` —
  `desktop/garyx-desktop/src/renderer/src/RecentFilterTabs.tsx` and
  `recent-conversation-sidebar-model.ts::recentFilterForArrowKey`.

Arrow-key traversal therefore visits them in a different order on each
platform. Cosmetic, but the Mac app is the IA source of truth, so one of the
two should move.

## 3. `npm run test:i18n-literals` fails on the main baseline

`desktop/garyx-desktop/src/renderer/src/message-rich-text-linebreaks.test.mjs:71,75`
contain Han literals, which the checker rejects outside `src/renderer/src/i18n`.

Confirmed pre-existing: the same failure reproduces on a clean checkout with no
local changes. Either move those fixtures behind synthetic ASCII strings or
extend the checker's allowlist to test files.

## 4. The gateway's third recent filter is unreachable from either client

`/api/recent-threads?tasks=only` exists and is validated server-side
(`garyx-gateway/src/routes/threads.rs`), but neither desktop nor iOS exposes it.
Either surface it as a "Tasks" filter or drop it from the wire contract.

## 5. Three hand-rolled segmented controls

`recent-filter-tabs`, `sidebar-tabs`, `tasks-segmented`, and
`capsules-segmented` each re-implement the same equal-width grid + active pill
recipe with their own CSS block. This change added `sidebar-tabs` to that list
rather than inventing a shared abstraction mid-task. Worth unifying into one
component once someone touches a second one of them.
