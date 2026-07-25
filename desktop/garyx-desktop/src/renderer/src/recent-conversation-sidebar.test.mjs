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

test("an all-pinned page still reads as primed, not as an empty feed", () => {
  // The pager keeps paging the unfiltered server unit, so a page whose rows are
  // all pinned renders empty while the feed is healthy. It must not claim a
  // loading state, and the near-tail loader stays available to fetch more.
  const feed = {
    isPrimed: true,
    isRefreshingHead: false,
    isLoadingMore: false,
    headFailure: null,
    loadGate: "ready",
    nextCursor: "cursor-2",
  };
  const presentation = recentConversationPresentation(feed, 0, "all");
  assert.equal(presentation.footerKind, "idle");
  assert.equal(presentation.emptyLabelKey, "No recent threads");
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
      feed({ isPrimed: true, isRefreshingHead: true }),
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
      feed({ isPrimed: true, headFailure: "offline" }),
      3,
      "all",
    ).footerKind,
    "cachedRefreshFailure",
  );
});

test("Recent presentation maps every load-more footer gate", () => {
  assert.equal(
    recentConversationPresentation(
      feed({ isPrimed: true, isLoadingMore: true }),
      3,
      "all",
    ).footerKind,
    "loadingMore",
  );
  assert.equal(
    recentConversationPresentation(
      feed({ isPrimed: true, loadGate: "failed" }),
      3,
      "all",
    ).footerKind,
    "loadMoreFailure",
  );
  assert.equal(
    recentConversationPresentation(
      feed({ isPrimed: true, nextCursor: "cursor-next" }),
      3,
      "all",
    ).footerKind,
    "idle",
  );
  assert.equal(
    recentConversationPresentation(
      feed({
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
