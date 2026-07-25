import assert from "node:assert/strict";
import test from "node:test";

import {
  excludePinnedFromRecent,
  recentConversationPresentation,
  recentFilterForArrowKey,
} from "./recent-conversation-sidebar-model.ts";
import { threadRailIsNearListEnd } from "./thread-conversation-sidebar-model.ts";

test("the recent list drops pinned threads and preserves server order", () => {
  const threads = [
    { id: "a" },
    { id: "b" },
    { id: "c" },
    { id: "d" },
  ];

  assert.deepEqual(
    excludePinnedFromRecent(threads, new Set(["b", "d"])).map((t) => t.id),
    ["a", "c"],
  );
  // No pins: every row survives, order untouched.
  assert.deepEqual(
    excludePinnedFromRecent(threads, new Set()).map((t) => t.id),
    ["a", "b", "c", "d"],
  );
  // Pins that are not in the feed change nothing.
  assert.deepEqual(
    excludePinnedFromRecent(threads, new Set(["zz"])).map((t) => t.id),
    ["a", "b", "c", "d"],
  );
  // Every row pinned is an empty list, not a fallback to the unfiltered feed.
  assert.deepEqual(
    excludePinnedFromRecent(threads, new Set(["a", "b", "c", "d"])),
    [],
  );
  assert.deepEqual(excludePinnedFromRecent([], new Set(["a"])), []);
  // Ids are matched exactly; near-misses stay visible.
  assert.deepEqual(
    excludePinnedFromRecent(threads, new Set([" a", "A"])).map((t) => t.id),
    ["a", "b", "c", "d"],
  );
  // The input is never mutated.
  assert.equal(threads.length, 4);
});

test("a fully-pinned page is not an empty feed", () => {
  // Pinned threads render in their own sidebar region, so a page can produce
  // zero rows while the server feed is not empty. Claiming "no recent threads"
  // there would contradict a visibly populated Pinned region.
  const primed = {
    isPrimed: true,
    isRefreshingHead: false,
    isLoadingMore: false,
    headFailure: null,
    loadGate: "ready",
    nextCursor: "cursor-2",
  };

  const allPinned = recentConversationPresentation(
    { ...primed, orderedThreadIds: ["pinned-a", "pinned-b"] },
    0,
    "all",
  );
  assert.equal(allPinned.emptyLabelKey, null);
  assert.equal(allPinned.footerKind, "idle");

  // Same for the sidebar's Chats list and for Favorites.
  assert.equal(
    recentConversationPresentation(
      { ...primed, orderedThreadIds: ["pinned-a"] },
      0,
      "nonTask",
    ).emptyLabelKey,
    null,
  );
  assert.equal(
    recentConversationPresentation(
      { ...primed, loadGate: "exhausted", nextCursor: null, orderedThreadIds: ["pinned-a"] },
      0,
      "favorites",
    ).emptyLabelKey,
    null,
  );

  // A genuinely empty server feed still reports empty, per filter.
  const emptyFeed = { ...primed, loadGate: "exhausted", nextCursor: null, orderedThreadIds: [] };
  assert.equal(
    recentConversationPresentation(emptyFeed, 0, "all").emptyLabelKey,
    "No recent threads",
  );
  assert.equal(
    recentConversationPresentation(emptyFeed, 0, "nonTask").emptyLabelKey,
    "No recent chats",
  );
  assert.equal(
    recentConversationPresentation(emptyFeed, 0, "favorites").emptyLabelKey,
    "No favorite threads",
  );

  // An unprimed feed is loading, never empty.
  assert.equal(
    recentConversationPresentation(
      { ...primed, isPrimed: false, orderedThreadIds: [] },
      0,
      "nonTask",
    ).footerKind,
    "initialLoading",
  );
});

test("Recent segmented tabs switch with both arrow keys", () => {
  assert.equal(recentFilterForArrowKey("nonTask", "ArrowRight"), "all");
  assert.equal(recentFilterForArrowKey("all", "ArrowRight"), "favorites");
  assert.equal(recentFilterForArrowKey("favorites", "ArrowRight"), "nonTask");
  assert.equal(recentFilterForArrowKey("nonTask", "ArrowLeft"), "favorites");
  assert.equal(recentFilterForArrowKey("favorites", "ArrowLeft"), "all");
  assert.equal(recentFilterForArrowKey("all", "ArrowLeft"), "nonTask");
});

test("shared rail near-tail seam triggers only inside the threshold", () => {
  assert.equal(
    threadRailIsNearListEnd({
      clientHeight: 400,
      scrollHeight: 1_000,
      scrollTop: 439,
    }),
    false,
  );
  assert.equal(
    threadRailIsNearListEnd({
      clientHeight: 400,
      scrollHeight: 1_000,
      scrollTop: 440,
    }),
    true,
  );
  assert.equal(
    threadRailIsNearListEnd({
      clientHeight: 500,
      scrollHeight: 320,
      scrollTop: 0,
    }),
    true,
  );
});

function feed(overrides = {}) {
  return {
    orderedThreadIds: [],
    isPrimed: false,
    isRefreshingHead: false,
    isLoadingMore: false,
    headFailure: null,
    loadGate: "ready",
    nextCursor: null,
    epoch: 0,
    localMutationSequence: 0,
    loadMoreFailureRevision: 0,
    activeRefreshRequestId: null,
    activeLoadMoreRequestId: null,
    refreshAfterMutation: false,
    loadMoreAfterMutation: false,
    ...overrides,
  };
}

// A rendered row count is always derived from the server feed (summary lookup
// plus the pinned exclusion), so it can never exceed that feed's length. Keep
// fixtures self-consistent: any case that renders N rows needs >= N feed ids.
function feedHolding(count, overrides = {}) {
  return feed({
    orderedThreadIds: Array.from({ length: count }, (_, i) => `thread-${i}`),
    ...overrides,
  });
}

test("Recent presentation distinguishes initial, empty, and cached refresh states", () => {
  assert.deepEqual(recentConversationPresentation(feed(), 0, "all"), {
    emptyLabelKey: null,
    footerKind: "initialLoading",
  });
  assert.deepEqual(
    recentConversationPresentation(feed({ isPrimed: true }), 0, "all"),
    { emptyLabelKey: "No recent threads", footerKind: "hidden" },
  );
  assert.deepEqual(
    recentConversationPresentation(feed({ isPrimed: true }), 0, "nonTask"),
    { emptyLabelKey: "No recent chats", footerKind: "hidden" },
  );
  assert.deepEqual(
    recentConversationPresentation(feed({ isPrimed: true }), 0, "favorites"),
    { emptyLabelKey: "No favorite threads", footerKind: "hidden" },
  );
  assert.deepEqual(
    recentConversationPresentation(
      feedHolding(3, { isPrimed: true, isRefreshingHead: true }),
      3,
      "all",
    ),
    { emptyLabelKey: null, footerKind: "hidden" },
  );
  assert.equal(
    recentConversationPresentation(
      feed({ headFailure: "offline" }),
      0,
      "all",
    ).footerKind,
    "initialFailure",
  );
  assert.equal(
    recentConversationPresentation(
      feedHolding(3, { isPrimed: true, headFailure: "offline" }),
      3,
      "all",
    ).footerKind,
    "cachedRefreshFailure",
  );
});

test("Recent presentation maps every load-more footer gate", () => {
  assert.equal(
    recentConversationPresentation(
      feedHolding(3, { isPrimed: true, isLoadingMore: true }),
      3,
      "all",
    ).footerKind,
    "loadingMore",
  );
  assert.equal(
    recentConversationPresentation(
      feedHolding(3, { isPrimed: true, loadGate: "failed" }),
      3,
      "all",
    ).footerKind,
    "loadMoreFailure",
  );
  assert.equal(
    recentConversationPresentation(
      feedHolding(3, { isPrimed: true, nextCursor: "cursor-next" }),
      3,
      "all",
    ).footerKind,
    "idle",
  );
  assert.equal(
    recentConversationPresentation(
      feedHolding(3, {
        isPrimed: true,
        loadGate: "exhausted",
        nextCursor: "cursor-next",
      }),
      3,
      "all",
    ).footerKind,
    "hidden",
  );
});
