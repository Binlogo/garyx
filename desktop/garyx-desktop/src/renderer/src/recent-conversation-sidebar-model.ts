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
  const emptyLabelKey =
    feed.isPrimed && rowCount === 0 && !feed.headFailure
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

export function recentFilterForArrowKey(
  current: RecentThreadFilter,
  key: "ArrowLeft" | "ArrowRight",
): RecentThreadFilter {
  const filters: RecentThreadFilter[] = ["nonTask", "all", "favorites"];
  const currentIndex = filters.indexOf(current);
  const delta = key === "ArrowRight" ? 1 : -1;
  return filters[(currentIndex + delta + filters.length) % filters.length];
}
