import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const recentSidebar = readFileSync(
  new URL("./RecentConversationSidebar.tsx", import.meta.url),
  "utf8",
);
const sidebarRecentList = readFileSync(
  new URL("./SidebarRecentThreadList.tsx", import.meta.url),
  "utf8",
);
const appShell = readFileSync(
  new URL("./app-shell/AppShell.tsx", import.meta.url),
  "utf8",
);
const conversationHeader = readFileSync(
  new URL("./ConversationHeaderTitle.tsx", import.meta.url),
  "utf8",
);
const sharedThreadRail = readFileSync(
  new URL("./ThreadRailList.tsx", import.meta.url),
  "utf8",
);
const workspaceRails = readFileSync(
  new URL("./styles/workspace-rails.css", import.meta.url),
  "utf8",
);
const hook = readFileSync(
  new URL("./app-shell/useRecentThreadFeeds.ts", import.meta.url),
  "utf8",
);
const preload = readFileSync(
  new URL("../../preload/index.ts", import.meta.url),
  "utf8",
);
const main = readFileSync(
  new URL("../../main/index.ts", import.meta.url),
  "utf8",
);

test("the filter control belongs to the rail, never to the sidebar tab", () => {
  // Segmented semantics and keyboard behaviour are covered by real behaviour
  // tests in components/segmented-control.test.mjs; what matters here is only
  // WHICH surface owns a filter at all.
  assert.match(recentSidebar, /import \{ RecentFilterTabs \}/);
  assert.match(recentSidebar, /<RecentFilterTabs/);
  assert.doesNotMatch(recentSidebar, /role="tablist"/);
  // The sidebar's Threads tab shows the chat list directly: no filter control,
  // and no filter selection plumbing at all.
  assert.doesNotMatch(sidebarRecentList, /RecentFilterTabs/);
  assert.doesNotMatch(sidebarRecentList, /role="tablist"/);
  assert.doesNotMatch(sidebarRecentList, /selectedFilter/);
  assert.doesNotMatch(sidebarRecentList, /onSelectFilter/);
  assert.doesNotMatch(sidebarRecentList, /favorites/);
});

test("the sidebar Threads tab is bound to the Chats feed by name", () => {
  // It must not follow the rail's selectedFilter, so the hook keeps that feed
  // refreshed while the tab is showing and exposes it by name.
  assert.match(appShell, /keepChatsFeedActive: sidebarTab === "threads"/);
  assert.match(appShell, /feed=\{recentThreadFeeds\.chatsFeed\}/);
  assert.match(appShell, /onLoadMore=\{recentThreadFeeds\.loadMoreChats\}/);
  assert.match(appShell, /onRetry=\{recentThreadFeeds\.retryChats\}/);
  assert.match(hook, /keepChatsFeedActive && !filters\.includes\("nonTask"\)/);
  assert.match(hook, /chatsThreads: recentThreadSummariesForFilter\(/);
  // The Chats list never carries the Favorites-only unfavorite accessory.
  assert.match(appShell, /threadRailRowsFrom\(sidebarChatRows, false\)/);
  assert.match(
    appShell,
    /threadRailRowsFrom\(recentThreadRows, showingFavoriteThreads\)/,
  );
});

test("Desktop favorite controls share the pin menu and Favorites row accessory", () => {
  const pinMenuItem = conversationHeader.indexOf(
    "<DropdownMenuItem onSelect={onTogglePinnedThread}>",
  );
  const favoriteMenuItem = conversationHeader.indexOf(
    "<DropdownMenuItem onSelect={onToggleFavoriteThread}>",
  );
  assert.ok(pinMenuItem >= 0);
  assert.ok(favoriteMenuItem > pinMenuItem);
  assert.match(conversationHeader, /<StarOff aria-hidden \/> : <Star aria-hidden \/>/);
  assert.match(sharedThreadRail, /onUnfavorite\?: \(\) => void/);
  assert.match(sharedThreadRail, /row\.onUnfavorite && !isConfirming/);
  assert.match(sharedThreadRail, /aria-label=\{t\('Unfavorite conversation'\)\}/);
  assert.match(
    workspaceRails,
    /\.thread-delete-button\.thread-unfavorite-button\s*\{\s*right: 32px;/,
  );
  // The unfavorite accessory is gated per surface by the shared row mapper;
  // only the rail's Favorites filter enables it (asserted in detail below).
  assert.match(appShell, /onUnfavorite: allowUnfavorite/);
  assert.match(appShell, /onArchive: row\.isBusy/);
});

test("AppShell owns the feed hook outside the conditional rail", () => {
  const hookOwner = appShell.indexOf("const recentThreadFeeds = useRecentThreadFeeds");
  const recentRowsStart = appShell.indexOf("const recentThreadRows = useMemo");
  const pinnedRowsStart = appShell.indexOf("const pinnedThreadRows = useMemo");
  const conditionalRail = appShell.indexOf("<RecentConversationSidebar");
  assert.ok(hookOwner >= 0);
  assert.ok(recentRowsStart > hookOwner);
  assert.ok(pinnedRowsStart > recentRowsStart);
  assert.ok(conditionalRail > hookOwner);
  const recentRowsOwner = appShell.slice(recentRowsStart, pinnedRowsStart);
  assert.match(recentRowsOwner, /visibleRecentThreads\.map\(\(thread\) => \(\{/);
  assert.match(hook, /resetRecentThreadFeedsScope/);
  assert.match(appShell, /gatewayScope: desktopState\?\.entitiesGatewayUrl \|\| ""/);
  assert.doesNotMatch(
    appShell,
    /gatewayScope:[\s\S]{0,160}desktopState\?\.settings\.gatewayUrl/,
  );
  assert.match(
    appShell,
    /onTaskCreated=\{\(\) => \{\s*recentThreadFeeds\.noteAllLocalMutation\(\);\s*recentThreadFeeds\.refreshAll\(\);/,
  );
  assert.match(hook, /queuedRefreshesRef\.current\.add\("all"\)/);
});

test("one feed serves both recent surfaces and either consumer keeps it alive", () => {
  // The L1 Threads tab and the L2 recent rail share one hook, one filter
  // selection, one pager, and one row mapping. Neither may fetch on its own.
  assert.match(
    appShell,
    /const recentFeedWanted =\s*\n?\s*sidebarTab === "threads" \|\|\s*\n?\s*\(shouldShowConversationRail && recentThreadsRailOpen\);/,
  );
  assert.match(appShell, /enabled: recentFeedWanted/);
  const hookOwner = appShell.indexOf("const recentThreadFeeds = useRecentThreadFeeds");
  const rowMapper = appShell.indexOf("function threadRailRowsFrom(");
  assert.ok(rowMapper > hookOwner);
  // One hook, one row mapper, one presentation model behind both surfaces.
  assert.equal(
    appShell.match(/useRecentThreadFeeds\(\{/g)?.length,
    1,
    "a second feed hook would give the surfaces divergent data",
  );
  assert.equal(appShell.match(/threadRailRowsFrom\(/g)?.length, 3);
  assert.match(sidebarRecentList, /recentConversationPresentation/);
  // Collapse must not gate the feed: expanding L1 shows data immediately.
  assert.doesNotMatch(appShell, /enabled:[^\n]*sidebarCollapsed/);
});

test("the recent list never repeats the sidebar's pinned region", () => {
  // Pinned threads have their own always-visible region, so BOTH recent
  // surfaces must exclude them: the rail's feed and the sidebar's chat list.
  // Pin each call site by name — asserting only that some call exists would let
  // one surface silently lose its filter.
  const calls = appShell.match(/excludePinnedFromRecent\(/g) ?? [];
  assert.equal(calls.length, 2, "expected exactly one filter per recent surface");
  // Rail: applied where the selected feed's threads are derived.
  assert.match(
    appShell,
    /excludePinnedFromRecent\(\s*\n\s*showingFavoriteThreads[\s\S]{0,220}?pinnedThreadIdSet,/,
  );
  // Sidebar: applied to the Chats feed read by name.
  assert.match(
    appShell,
    /excludePinnedFromRecent\(\s*\n\s*recentThreadFeeds\.chatsThreads,\s*\n\s*pinnedThreadIdSet,/,
  );
  // Never re-derived inside a view.
  assert.doesNotMatch(recentSidebar, /excludePinnedFromRecent/);
  assert.doesNotMatch(sidebarRecentList, /excludePinnedFromRecent/);
});

test("emptiness is decided by the server feed, not by the filtered row count", () => {
  // A fully-pinned page renders zero rows while the feed is populated; the
  // empty-state copy must not fire there. Pin the source of that decision.
  const model = readFileSync(
    new URL("./recent-conversation-sidebar-model.ts", import.meta.url),
    "utf8",
  );
  assert.match(model, /const serverFeedIsEmpty = feed\.orderedThreadIds\.length === 0;/);
  assert.match(model, /feed\.isPrimed && serverFeedIsEmpty && !feed\.headFailure/);
  assert.doesNotMatch(model, /feed\.isPrimed && rowCount === 0/);
});

test("closing Recent retains its content until the layout frame releases the rail", () => {
  assert.match(appShell, /deferConversationRailUnmount/);
  assert.match(appShell, /settleDeferredConversationRailUnmount/);
  assert.doesNotMatch(
    appShell,
    /<div aria-hidden="true" className="bot-conversation-rail" \/>/,
  );
});

test("preload forwards a narrow input while only main owns the Recent URL", () => {
  assert.match(
    preload,
    /ipcRenderer\.invoke\("garyx:list-recent-threads", input\)/,
  );
  assert.doesNotMatch(preload, /api\/recent-threads/);
  assert.match(main, /validateListRecentThreadsInput\(rawInput\)/);
  assert.match(main, /assertRecentThreadGatewayScope\(settings, input\.gatewayScope\)/);
  assert.doesNotMatch(appShell, /api\/recent-threads/);
  assert.doesNotMatch(hook, /api\/recent-threads/);
});
