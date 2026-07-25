import type {
  RecentThreadFeedState,
  RecentThreadFilter,
} from "./app-shell/recent-thread-feeds";

export type RecentFeedFooterKind =
  | "hidden"
  | "initialLoading"
  | "initialFailure"
  | "cachedRefreshFailure"
  | "loadingMore"
  | "loadMoreFailure"
  | "idle";

export type RecentConversationPresentation = {
  emptyLabelKey:
    | "No recent threads"
    | "No recent chats"
    | "No favorite threads"
    | null;
  footerKind: RecentFeedFooterKind;
};

export function recentConversationPresentation(
  feed: RecentThreadFeedState,
  rowCount: number,
  selectedFilter: RecentThreadFilter,
): RecentConversationPresentation {
  const isInitialLoading =
    !feed.isPrimed &&
    !feed.headFailure &&
    (feed.isRefreshingHead || rowCount === 0);
  // `rowCount` is what actually renders, after pinned threads are excluded, and
  // it drives the loading skeleton. Emptiness is a different question: the
  // pinned region shows those threads separately, so a page can render zero rows
  // while the server feed is not empty at all. Claiming "no recent chats" there
  // would contradict a visibly populated Pinned region — and would be plainly
  // wrong while a next page is still being fetched. Only a genuinely empty
  // server feed is an empty state.
  const serverFeedIsEmpty = feed.orderedThreadIds.length === 0;
  const emptyLabelKey =
    feed.isPrimed && serverFeedIsEmpty && !feed.headFailure
      ? selectedFilter === "all"
        ? "No recent threads"
        : selectedFilter === "nonTask"
          ? "No recent chats"
          : "No favorite threads"
      : null;

  if (isInitialLoading) {
    return { emptyLabelKey, footerKind: "initialLoading" };
  }
  if (feed.headFailure) {
    return {
      emptyLabelKey,
      footerKind: feed.isPrimed
        ? "cachedRefreshFailure"
        : "initialFailure",
    };
  }
  if (feed.isLoadingMore) {
    return { emptyLabelKey, footerKind: "loadingMore" };
  }
  if (feed.loadGate === "failed") {
    return { emptyLabelKey, footerKind: "loadMoreFailure" };
  }
  if (feed.loadGate === "ready" && feed.nextCursor !== null) {
    return { emptyLabelKey, footerKind: "idle" };
  }
  return { emptyLabelKey, footerKind: "hidden" };
}

/**
 * Drop threads that are already shown in the sidebar's Pinned region.
 *
 * Presentation-only, matching iOS (`GaryxHomeThreadListPresentation.swift`):
 * ordering and membership still come from the server-owned unit, and the keyset
 * pager keeps paging over the unfiltered feed. A page containing pinned rows
 * therefore renders slightly short, which is expected — the near-tail loader
 * simply asks for the next page sooner.
 */
export function excludePinnedFromRecent<T extends { id: string }>(
  threads: readonly T[],
  pinnedThreadIds: ReadonlySet<string>,
): T[] {
  return threads.filter((thread) => !pinnedThreadIds.has(thread.id));
}

// Arrow-key traversal now lives in the shared SegmentedControl, which walks the
// option array it is given. `RecentFilterTabs` owns that order; a second
// ordering constant here would be a duplicate source of truth.
