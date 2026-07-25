import { type ComponentProps, type ReactNode } from "react";

import type {
  RecentThreadFeedState,
  RecentThreadFilter,
} from "./app-shell/recent-thread-feeds";
import { recentFeedFooter } from "./recent-feed-footer";
import { RecentFilterTabs } from "./RecentFilterTabs";
import {
  ThreadConversationSidebar,
  type ThreadRailRow,
} from "./ThreadConversationSidebar";
import { useI18n } from "./i18n";
import { recentConversationPresentation } from "./recent-conversation-sidebar-model";

type RecentConversationSidebarProps = {
  collapseLabel: string;
  feed: RecentThreadFeedState;
  formatThreadTimestamp: (value?: string | null) => string;
  logo: ReactNode;
  onClose: () => void;
  onLoadMore?: () => void;
  onRailResizeStart?: ComponentProps<
    typeof ThreadConversationSidebar
  >["onRailResizeStart"];
  onRetry: () => void;
  onSelectFilter: (filter: RecentThreadFilter) => void;
  railResizing?: boolean;
  rows: ThreadRailRow[];
  selectedFilter: RecentThreadFilter;
};

/**
 * The L2 recent rail: the wide, side-by-side form of the recent thread list,
 * opened from the sidebar's Recent entry. The L1 sidebar Threads tab renders
 * the same feed through {@link SidebarRecentThreadList}; both share one
 * AppShell-owned feed, filter selection, and pager.
 */
export function RecentConversationSidebar({
  collapseLabel,
  feed,
  formatThreadTimestamp,
  logo,
  onClose,
  onLoadMore,
  onRailResizeStart,
  onRetry,
  onSelectFilter,
  railResizing,
  rows,
  selectedFilter,
}: RecentConversationSidebarProps) {
  const { t } = useI18n();
  const presentation = recentConversationPresentation(
    feed,
    rows.length,
    selectedFilter,
  );

  return (
    <ThreadConversationSidebar
      ariaLabel={t("Recent threads")}
      className="recent-conversation-rail"
      collapseLabel={collapseLabel}
      emptyLabel={
        presentation.emptyLabelKey ? t(presentation.emptyLabelKey) : undefined
      }
      formatThreadTimestamp={formatThreadTimestamp}
      headerAccessory={
        <RecentFilterTabs
          onSelectFilter={onSelectFilter}
          selectedFilter={selectedFilter}
        />
      }
      listFooter={recentFeedFooter({
        kind: presentation.footerKind,
        onRetry,
        t,
      })}
      logo={logo}
      onClose={onClose}
      onNearListEnd={
        onLoadMore && feed.loadGate === "ready" ? onLoadMore : undefined
      }
      onRailResizeStart={onRailResizeStart}
      railResizing={railResizing}
      rowClassName="recent-conversation-row-shell"
      rows={rows}
      title={t("Recent")}
    />
  );
}
