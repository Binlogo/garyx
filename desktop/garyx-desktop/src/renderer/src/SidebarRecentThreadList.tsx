import type { RecentThreadFeedState } from "./app-shell/recent-thread-feeds";
import { recentFeedFooter } from "./recent-feed-footer";
import { ThreadRailList, type ThreadRailRow } from "./ThreadRailList";
import { useI18n } from "./i18n";
import { recentConversationPresentation } from "./recent-conversation-sidebar-model";

type SidebarRecentThreadListProps = {
  feed: RecentThreadFeedState;
  formatThreadTimestamp: (value?: string | null) => string;
  onLoadMore?: () => void;
  onRetry: () => void;
  rows: ThreadRailRow[];
};

/**
 * The sidebar's Threads tab: the chat list, shown directly with no filter
 * control. This surface IS the Chats feed — it does not follow the L2 recent
 * rail's filter selection, and All / Favorites stay exclusive to that rail.
 */
export function SidebarRecentThreadList({
  feed,
  formatThreadTimestamp,
  onLoadMore,
  onRetry,
  rows,
}: SidebarRecentThreadListProps) {
  const { t } = useI18n();
  const presentation = recentConversationPresentation(
    feed,
    rows.length,
    "nonTask",
  );

  return (
    <ThreadRailList
      className="sidebar-recent-rows"
      emptyLabel={
        presentation.emptyLabelKey ? t(presentation.emptyLabelKey) : undefined
      }
      formatThreadTimestamp={formatThreadTimestamp}
      listFooter={recentFeedFooter({
        kind: presentation.footerKind,
        onRetry,
        t,
      })}
      onNearListEnd={
        onLoadMore && feed.loadGate === "ready" ? onLoadMore : undefined
      }
      rowClassName="recent-conversation-row-shell"
      rows={rows}
    />
  );
}
