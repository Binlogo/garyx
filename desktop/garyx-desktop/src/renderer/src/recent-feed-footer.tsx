import type { ReactNode } from "react";

import type { RecentFeedFooterKind } from "./recent-conversation-sidebar-model";

/**
 * Feed-state footer for the recent thread list, shared by the L1 sidebar
 * Threads tab and the L2 recent rail. The footer kind is derived by
 * `recentConversationPresentation`; this module only renders it.
 */
export function recentFeedFooter({
  kind,
  onRetry,
  t,
}: {
  kind: RecentFeedFooterKind;
  onRetry: () => void;
  t: (key: string) => string;
}): ReactNode {
  if (kind === "initialLoading") {
    return (
      <div
        aria-label={t("Loading recent threads")}
        className="recent-feed-skeleton"
        role="status"
      >
        <span />
        <span />
        <span />
      </div>
    );
  }
  if (kind === "initialFailure" || kind === "cachedRefreshFailure") {
    return (
      <button className="recent-feed-footer failed" onClick={onRetry} type="button">
        {kind === "cachedRefreshFailure"
          ? t("Couldn't refresh · Retry")
          : t("Recent threads unavailable · Retry")}
      </button>
    );
  }
  if (kind === "loadingMore") {
    return (
      <div className="recent-feed-footer loading" role="status">
        <span aria-hidden className="recent-feed-spinner" />
        {t("Loading more")}
      </div>
    );
  }
  if (kind === "loadMoreFailure") {
    return (
      <button className="recent-feed-footer failed" onClick={onRetry} type="button">
        {t("Couldn't load more · Retry")}
      </button>
    );
  }
  if (kind === "idle") {
    return <div aria-hidden className="recent-feed-footer idle" />;
  }
  return null;
}
