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
  `desktop/garyx-desktop/src/renderer/src/RecentFilterTabs.tsx`, whose option
  array is now the single source of order (arrow-key traversal follows it).

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

## 5. Three hand-rolled segmented controls — RESOLVED

Closed by `components/SegmentedControl.tsx` + `styles/segmented.css`: one recipe,
two layouts (`fill`, `inline`), one accessibility contract.

All four surfaces are radio groups, including the sidebar's Threads/Projects
switch. The tabs pattern was considered and rejected: it requires every tab to
reference its own tabpanel, which means keeping every panel mounted, and the
Threads panel holds hundreds of rows. A single dynamic panel with two tabs
pointing at it is worse than either option — it tells assistive tech that the
inactive tab controls the panel the active one labels.

## 6. No DOM-interaction test path for shared components

Shipped as debt by owner decision (2026-07-25) after review of #TASK-2708
confirmed the runtime behaviour correct but the test contract incomplete.

Two gaps, both verified by the reviewer with mutation testing:

1. **Event wiring is unobservable.** Deleting `onKeyDown` from
   `components/SegmentedControl.tsx` leaves `segmented-control.test.mjs` at 9/9
   PASS. The suite renders through `renderToStaticMarkup`, and SSR markup cannot
   express React event handlers, so a refactor that drops the binding would kill
   all four arrow keys silently.
2. **Two of four callers are uncovered.** Only `SidebarTabs` and
   `RecentFilterTabs` are light enough to render in the SSR harness.
   `TasksPanel` and `CapsulesPanel` depend on the desktop API. Deleting
   `layout="inline"` from the Tasks call site regresses it to the fill layout
   while `tsc`, the focused suite, and all 1007 unit tests stay green.

The repository has no DOM-mount infrastructure at all: no jsdom, linkedom, or
happy-dom, and no test uses `createRoot` or `dispatchEvent`. Closing these needs
one of:

- a jsdom (or similar) devDependency plus a mount-and-dispatch helper, or
- a Playwright component-interaction path, reusing the installed Playwright.

Whichever is chosen, do **not** close them by reintroducing source-scanning
regex guards — that violates the structural-guards rule in `AGENTS.md`, and the
retired version of those guards failed to catch a `height` override, a `:hover`
rule, and a `box-shadow` removal.

Extracting the Tasks and Capsules call sites into thin wrapper components (the
shape `SidebarTabs` and `RecentFilterTabs` already have) would make gap 2
testable in the existing SSR harness and make all four surfaces symmetric.
