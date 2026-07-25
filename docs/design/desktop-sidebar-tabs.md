# Desktop Sidebar Tabs: Threads / Projects

Owner: Gary · Date: 2026-07-25 · Status: approved for implementation

## 1. Problem

The Mac app's L1 sidebar mixes four unrelated concerns in one vertical stack:
global module entries, pinned threads, bots, and workspaces. The recent chat
list lives somewhere else entirely — an L2 conversation rail that only appears
after clicking the `Recent` nav entry — so the most frequently used surface
(the chat list) is one click away and occupies a second track.

Two concrete defects:

1. **The chat list is not a first-class sidebar citizen.** It is only reachable
   as an optional L2 rail behind the `Recent` nav entry. Reading the chat list
   always costs a click plus 258px of horizontal space.
2. **Pinned threads are shown twice.** The L1 pinned block and the recent list
   both render the same threads. iOS already de-duplicates
   (`GaryxHomeThreadListPresentation.swift:732` filters
   `!pinnedIdSet.contains($0)`); the Mac app does not.

## 2. Decision (owner-approved)

Tab-ify the L1 sidebar into **Threads** and **Projects**. Pinned stays a
separate always-visible region *above* the tabs, not inside either tab.

```
.left-rail
├─ sidebar-update-slot          UpdatePill                        (unchanged)
├─ nav.sidebar-nav              New Thread · Automation · Capsules ·
│                               Tasks · Agents · Skills · Recent
│                               ← ALL entries kept, `Recent` included
├─ PinnedThreadsSidebar         independent region, always visible,
│                               NOT part of any tab
├─ sidebar-tabs                 NEW segmented control: Threads | Projects
├─ sidebar-tab-panel            the tab body
│  ├─ Threads: recent-filter segmented (All | Chats | Favorites)
│  │           + recent thread list + feed footer
│  └─ Projects: BotSidebar + WorkspaceThreadSidebar
├─ sidebar-footer               gateway identity + settings   (unchanged)
└─ sidebar-resizer                                            (unchanged)
```

Consequences, all in scope:

- **The `Recent` nav entry stays, and the L2 recent rail stays** (owner
  decision, 2026-07-25). Clicking `Recent` still opens the wide L2 rail,
  behavior unchanged. The L1 Threads tab is an *additional*, always-present
  view of the same list — the L2 rail remains the roomy side-by-side form.
- Both surfaces render **one feed**: the `AppShell`-owned
  `useRecentThreadFeeds` state, one selected filter, one keyset pager. There
  is no second fetch pipeline, no second filter selection, and no second
  removed-threads tombstone set. Switching the filter in one surface switches
  it in the other, by construction.
- The recent list keeps everything it has today: three filters, keyset
  infinite scroll, footer states (initial loading / failure / loading-more /
  load-more failure / idle), favorites atomic snapshot source.
- Both surfaces **exclude pinned threads**, for all three filters (matching
  iOS, where the pinned filter applies to `visibleRecentThreadIds` regardless
  of selected filter). This falls out for free from the shared derivation —
  see §3.3.

### 2.1 Rejected alternatives

| Alternative | Why not |
|---|---|
| Delete the `Recent` nav entry / retire the L2 rail once the Threads tab exists | Owner explicitly kept both. The L2 rail is the wide side-by-side reading form; the L1 tab is the always-visible compact form. |
| Give the L1 tab and the L2 rail independent filter selections | Two sources of truth for one question ("which filter am I on"), and two pagers over the same server unit. One feed, two renderers. |
| Put Pinned inside the Threads tab | Owner decision: pinned is a separate region. It must stay reachable while browsing Projects. |
| Collapse the filter segmented into a menu (iOS style) | More UI design work, not requested. Noted as a follow-up option if the two stacked segmented rows read heavy — see §7. |

## 3. Architecture

### 3.1 Tab state

New renderer-owned state, `"threads" | "projects"`, persisted to
`localStorage["garyx.sidebarTab"]` following the existing
`garyx.sidebarCollapsed` pattern in
`app-shell/useLayoutResizeController.ts:52-58` / `:325-334`. Unknown or
missing values fall back to `"threads"`.

Keep the read/write/normalize logic as **pure functions in a model module**
with unit tests — no inline `localStorage` access in JSX.

### 3.2 Recent feed lifecycle

`useRecentThreadFeeds` (`app-shell/useRecentThreadFeeds.ts`, called from
`AppShell.tsx:1946`) currently gates on
`enabled: shouldShowConversationRail && recentThreadsRailOpen`.

New gate: **either consumer wants the data** — the Threads tab is selected, or
the L2 recent rail is open. Express it as one named boolean derived from both,
not as two hook calls.

Do *not* additionally gate on L1 collapse state — collapse is a transient
visual state and an expand must show data immediately, not restart a cold
fetch.

The hook must stay owned by `AppShell` (not by a conditionally-mounted tab
component). `recent-filter-source-contract.test.mjs` pins this ownership plus
the declaration order `recentThreadFeeds` → `recentThreadRows` →
`pinnedThreadRows`; preserve that ordering.

That contract test's deferred-unmount case is about the L2 rail and stays
valid as-is. **Add** a case for the new gate: selecting Projects while the L2
rail is closed disables the feed; either consumer alone keeps it enabled.

### 3.3 Pinned de-duplication

The filter is a pure presentation-layer exclusion. It must **not** touch the
keyset pager: cursors are opaque server tokens derived from server-returned
rows, and `feed.orderedThreadIds` stays the untouched server-owned unit.

Add a pure function, tested, e.g.:

```ts
excludePinnedFromRecent(threads: DesktopThreadSummary[], pinnedThreadIds: readonly string[]): DesktopThreadSummary[]
```

Apply it in exactly one place — where `visibleRecentThreads` is computed
(`AppShell.tsx:2012-2014`) — so it covers the keyset branch, the favorites
branch, **and both renderers** (L1 tab and L2 rail) from a single derivation.
Do not filter inside either view component.

Two consequences to handle explicitly:

1. **Short first page.** A 100-row page containing N pinned rows renders
   100−N. This is acceptable and matches iOS. The near-list-end loader
   (`onNearListEnd` / `threadRailIsNearListEnd`) already drives off rendered
   rows, so it will simply request the next page sooner.
2. **Empty-state ambiguity.** If every fetched row is pinned, the list renders
   empty while the feed is primed and healthy. Do not show the "no threads"
   copy in that case if it reads wrong — verify the resulting
   `recentConversationPresentation` state in the real app and adjust
   `recent-conversation-sidebar-model.ts` only if the empty label is
   misleading.

### 3.4 Component decomposition

`RecentConversationSidebar` today wraps `ThreadConversationSidebar`, which
supplies the L2 rail chrome: logo, title, collapse button, resizer hook, drag
region. None of that belongs in an L1 tab panel, but all of it must survive
for the L2 rail, which is staying.

There are now three consumers of the same list machinery: the L2 recent rail,
the L2 bot/workspace drilldown rail, and the new L1 Threads tab. So:

- Extract the reusable inner part — row rendering, list scroll container,
  near-list-end detection, footer slot — into a shared internal component.
- `ThreadConversationSidebar` keeps its rail chrome and composes that inner
  component. **L2 behavior must not change**: `RecentConversationSidebar` and
  `BotConversationSidebar` keep rendering exactly as they do today.
- A new `SidebarRecentThreadList` composes the same inner component with the
  filter segmented + footer, no rail chrome, for the L1 Threads tab.
- The filter segmented control and the `recentFeedFooter` renderer are used by
  both `RecentConversationSidebar` and `SidebarRecentThreadList`. Factor them
  into one shared unit rather than copying the JSX — a duplicated filter
  tablist would drift, and its a11y contract (`role=tablist` / `role=tab` /
  `aria-selected` / arrow-key navigation) is pinned by
  `recent-filter-source-contract.test.mjs`.

Reuse without modification: `recent-thread-feeds.ts` (reducer),
`recent-conversation-sidebar-model.ts` (`recentConversationPresentation`),
`recentThreadFilterLabel`, `ThreadRailRow`. (Arrow-key traversal later moved
into the shared `SegmentedControl`.)

### 3.5 CSS ownership

`.left-rail` itself is **not** a drag region — only its `::after` overlay
covering the top `var(--inset-toolbar)` strip is
(`styles/app-shell.css:45-55`). The new tab controls sit below `.sidebar-nav`,
outside that strip, so **no `-webkit-app-region` carveout is needed and
`styles/app-shell.css` must not be modified.**

All new rules go in `styles/sidebar.css`, using **new class names only**.
Hard constraints from `app-shell-owner-contract.test.mjs`:

- Never write `.left-rail`, `.app-shell`, `.bot-conversation-rail`,
  `.conversation`, `.sidebar-resizer`, or `.sidebar-collapse-toggle` in any
  stylesheet other than the owner (test 1 scans for escaped selectors). Style
  the new elements by their own classes.
- Never add `-webkit-app-region` to `sidebar.css` (test 4).
- `grid-template-columns` inside `sidebar.css` is fine; test 2's "exactly 5"
  count applies to the owner stylesheet only.
- No `@media` / `@container` anywhere in the owner stylesheet (unchanged).

Visual direction, per `desktop/garyx-desktop/CLAUDE.md` (Linear-like
restraint, warm neutrals, light mode only): the **Threads/Projects** segmented
is the stronger of the two rows; the filter segmented below it stays
lightweight so the pair does not read as two competing controls. Reuse the
`.recent-filter-tabs` recipe (`styles/workspace-rails.css:81-127`: equal-width
grid, 26px, 7px radius, white active pill) as the visual baseline.

### 3.6 Two independent scroll regions

Pinned is now a fixed sibling of the tab panel, so L1 has two scrollable
regions. Pinned gets `flex: 0 1 auto` with a max-height cap (~38% of the rail)
and its own overflow; the tab panel gets `flex: 1 1 auto; min-height: 0` and
its own overflow. A user with 20 pinned threads must not be able to push the
tab panel off-screen.

### 3.7 What must NOT change

Because both recent surfaces are staying, this change is **additive** on the
L2 side. Leave alone:

- `recentThreadsRailOpen`, `onOpenRecent`, `recentRailOpen`, the `Recent` nav
  button, `RecentIcon`, the Recent `ContentView` value, and the Recent route.
- The layout state machine (`app-shell/responsive-layout-model.ts`), its
  breakpoints (`SINGLE_RAIL_COMPACT_WIDTH` 720, `DUAL_RAIL_COMPACT_WIDTH`
  980), rail funding, and occupancy handling. The L1 tab adds no new track and
  no new occupant, so the state machine and all its tests should need **zero**
  changes. If an implementation seems to require touching it, that is a signal
  the L1 tab is being built as a track rather than as L1 content — stop and
  reconsider.
- `styles/app-shell.css` (see §3.5).

The only shared-code edits are the extraction in §3.4 (behavior-preserving)
and the feed gate in §3.2.

## 4. Non-goals / out of scope

Per the scope discipline rule: adjacent pre-existing issues found along the
way go into `docs/design/desktop-sidebar-tabs-review-debt.md` with their
source location, and are **not** folded into this change.

Explicitly out of scope:

- Persisting the recent **filter** selection (iOS persists it, Mac does not —
  a real divergence, but not this request). Record as debt.
- Filter-order divergence between iOS (`[all, nonTask, favorites]`) and Mac
  (`[nonTask, all, favorites]`). Record as debt.
- Exposing the gateway's third `tasks=only` filter.
- Any gateway, router, SQL, or `/api/recent-threads` change. This is a
  renderer-only change; the server contract is untouched.
- Any iOS change.
- Unifying the three hand-rolled segmented controls
  (`recent-filter-tabs`, `tasks-segmented`, `capsules-segmented`) into one
  shared component. Tempting, but it is a separate refactor.

## 5. Validation

Deterministic, in this order:

1. `npm run build:ui` — `tsc --noEmit` + electron-vite build, zero errors.
2. `npm run test:unit` — all green, including:
   - new pure-model tests: tab persistence round-trip + unknown-value
     fallback; `excludePinnedFromRecent` (pinned removed, order preserved,
     non-pinned untouched, empty/duplicate inputs).
   - `recent-filter-source-contract.test.mjs` — existing cases still pass
     (ownership, declaration order, a11y contract, deferred L2 unmount, the
     `api/recent-threads` literal ban), **plus** a new case for the
     either-consumer feed gate from §3.2.
   - untouched-and-still-green, with **no edits**:
     `app-shell-owner-contract.test.mjs`,
     `responsive-layout-design.test.mjs`, the whole
     `horizontal-layout-*` / `responsive-layout-model` suite,
     `recent-thread-feeds.test.mjs`, `favorites-ingress.test.mjs`,
     `recent-conversation-sidebar.test.mjs`,
     `sidebar-footer-design.test.mjs`. Needing to edit any of these is a
     design-violation signal, not a test-maintenance task.
3. `npm run test:i18n-literals` — all new copy goes through `t()`.
4. **Real packaged-app walkthrough** — `npm run dist:dir`, quit any stale
   `Garyx`, launch the installed app, attach with
   `playwright-cli -s=<session> attach --cdp=http://127.0.0.1:39222`.
   Capture screenshots for each:
   - Threads tab: list renders; All / Chats / Favorites all switch and load;
     scrolling to the end loads another page.
   - **Pinned threads appear in the pinned region and nowhere in the recent
     list** — the acceptance signal for §3.3. Verify in **both** surfaces:
     the L1 Threads tab and the L2 recent rail.
   - `Recent` nav entry still opens the L2 rail, unchanged. With both open at
     once, they show the same rows and the same selected filter; changing the
     filter in one moves the other.
   - Projects tab: bots and workspaces render; section collapse, row expand,
     workspace menu, add-bot / add-workspace all still work.
   - Tab selection survives an app restart.
   - Pinned region with many pinned rows does not crowd out the tab panel.
   - L1 collapse / expand / width drag still work; `compact-overlay` at
     ≤720px still works; ≤980px auto-hide of the L2 rail still works.
   - Opening a bot or workspace conversation still opens the L2 drilldown rail
     correctly.

## 6. Acceptance criteria

- L1 has a Threads / Projects segmented control; Pinned is a separate region
  above it and visible in both tabs.
- Threads tab = full recent list (3 filters, infinite scroll, footer states),
  with pinned threads excluded in all three filters.
- Projects tab = bots + workspaces, behavior unchanged from today.
- The `Recent` nav entry and the L2 recent rail still work exactly as before,
  now with pinned threads excluded there too.
- Both recent surfaces share one feed, one selected filter, one pager.
- Tab choice persists across restart.
- `styles/app-shell.css` unmodified; the layout state machine and its tests
  unmodified; all owner-contract tests green.
- Steps 1–4 of §5 all pass, with real screenshots for step 4.

## 7. Follow-up option (not part of this change)

If the stacked Threads/Projects + All/Chats/Favorites rows read visually
heavy in the real app, the filter row can later become a compact icon menu on
the tab row's trailing edge (closer to iOS, which uses a menu). Report the
observation with a screenshot; do not act on it in this change.
